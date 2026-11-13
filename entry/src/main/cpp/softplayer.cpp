/*
 * 软件解码（视频）native 管线
 * 设计：AVPlayer 负责解封装时钟与音频播放（ArkTS 侧），本模块用 OH_AVCodec 的
 * 软件解码器解视频帧并直接渲染到 XComponent 的 surface，按外部推送的时钟做帧调度。
 */
#include <cstdint>
#include <cstring>
#include <string>
#include <map>
#include <deque>
#include <mutex>
#include <thread>
#include <atomic>
#include <chrono>
#include <condition_variable>

#include "napi/native_api.h"
#include "multimedia/player_framework/native_avcodec_videodecoder.h"
#include "multimedia/player_framework/native_avcodec_base.h"
#include "multimedia/player_framework/native_avcapability.h"
#include "multimedia/player_framework/native_avdemuxer.h"
#include "multimedia/player_framework/native_avsource.h"
#include "multimedia/player_framework/native_avformat.h"
#include "multimedia/player_framework/native_avbuffer.h"
#include "multimedia/player_framework/native_averrors.h"
#include "native_window/external_window.h"

#define SOFT_TAG "SoftPlayer"

namespace {

int64_t NowMs()
{
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

class SoftPlayer {
public:
    SoftPlayer() {}
    ~SoftPlayer() { Release(); }

    int32_t Init(const std::string &surfaceId, int32_t fd, int64_t offset, int64_t length, bool preferSoftware)
    {
        window_ = nullptr;
        uint64_t sid = 0;
        try {
            sid = static_cast<uint64_t>(std::stoull(surfaceId));
        } catch (...) {
            return -1;
        }
        if (OH_NativeWindow_CreateNativeWindowFromSurfaceId(sid, &window_) != 0 || window_ == nullptr) {
            return -2;
        }

        source_ = OH_AVSource_CreateWithFD(fd, offset, length);
        if (source_ == nullptr) {
            return -3;
        }
        demuxer_ = OH_AVDemuxer_CreateWithSource(source_);
        if (demuxer_ == nullptr) {
            return -4;
        }

        OH_AVFormat *srcFormat = OH_AVSource_GetSourceFormat(source_);
        int32_t trackCount = 0;
        if (srcFormat == nullptr || !OH_AVFormat_GetIntValue(srcFormat, OH_MD_KEY_TRACK_COUNT, &trackCount)) {
            return -5;
        }

        std::string videoMime;
        for (int32_t i = 0; i < trackCount; i++) {
            OH_AVFormat *tf = OH_AVSource_GetTrackFormat(source_, static_cast<uint32_t>(i));
            if (tf == nullptr) {
                continue;
            }
            const char *mime = nullptr;
            if (OH_AVFormat_GetStringValue(tf, OH_MD_KEY_CODEC_MIME, &mime) && mime != nullptr) {
                std::string m(mime);
                if (m.rfind("video/", 0) == 0 && videoMime.empty()) {
                    videoMime = m;
                    trackIndex_ = i;
                    trackFormat_ = tf;
                } else {
                    OH_AVFormat_Destroy(tf);
                }
            } else {
                OH_AVFormat_Destroy(tf);
            }
        }
        if (videoMime.empty() || trackFormat_ == nullptr) {
            return -6;
        }
        mime_ = videoMime;

        if (preferSoftware) {
            OH_AVCapability *cap = OH_AVCodec_GetCapabilityByCategory(videoMime.c_str(), false, SOFTWARE);
            const char *name = cap != nullptr ? OH_AVCapability_GetName(cap) : nullptr;
            if (name != nullptr) {
                codecName_ = std::string(name);
                codec_ = OH_VideoDecoder_CreateByName(name);
            }
            if (codec_ == nullptr) {
                codec_ = OH_VideoDecoder_CreateByMime(videoMime.c_str());
                codecName_ = "auto:" + videoMime;
            }
        } else {
            codec_ = OH_VideoDecoder_CreateByMime(videoMime.c_str());
            codecName_ = "auto:" + videoMime;
        }
        if (codec_ == nullptr) {
            return -7;
        }

        OH_AVFormat *cfg = OH_AVFormat_Create();
        if (cfg == nullptr) {
            return -8;
        }
        OH_AVFormat_Copy(cfg, trackFormat_);

        // 视频软解输出到 surface
        if (OH_VideoDecoder_SetSurface(codec_, window_) != AV_ERR_OK) {
            OH_AVFormat_Destroy(cfg);
            return -9;
        }
        OH_AVErrCode ret = OH_VideoDecoder_Configure(codec_, cfg);
        OH_AVFormat_Destroy(cfg);
        if (ret != AV_ERR_OK) {
            return -10;
        }

        OH_AVCodecCallback cb;
        cb.onNeedInputBuffer = &SoftPlayer::OnNeedInputBuffer;
        cb.onNewOutputBuffer = &SoftPlayer::OnNewOutputBuffer;
        if (OH_VideoDecoder_RegisterCallback(codec_, cb, this) != AV_ERR_OK) {
            return -11;
        }
        if (OH_VideoDecoder_Prepare(codec_) != AV_ERR_OK) {
            return -12;
        }
        if (OH_AVDemuxer_SelectTrackByID(demuxer_, static_cast<uint32_t>(trackIndex_)) != AV_ERR_OK) {
            return -13;
        }
        if (OH_VideoDecoder_Start(codec_) != AV_ERR_OK) {
            return -14;
        }
        running_ = true;
        renderThread_ = std::thread(&SoftPlayer::RenderLoop, this);
        return 0;
    }

    void SetClock(int64_t ms)
    {
        clockMs_ = ms;
    }

    void SetPaused(bool paused)
    {
        paused_ = paused;
    }

    void SetSpeed(double speed)
    {
        speed_ = speed <= 0.0 ? 1.0 : speed;
    }

    void Seek(int64_t ms)
    {
        std::lock_guard<std::mutex> guard(demuxMutex_);
        pendingSeek_ = true;
        seekTarget_ = ms;
        clockMs_ = ms;
        {
            std::lock_guard<std::mutex> q(queMutex_);
            while (!renderQueue_.empty()) {
                renderQueue_.pop_front();
            }
        }
        if (codec_ != nullptr) {
            OH_VideoDecoder_Flush(codec_);
        }
        eosPending_ = false;
        firstFrame_ = true;
    }

    void Release()
    {
        if (released_) {
            return;
        }
        released_ = true;
        running_ = false;
        queCv_.notify_all();
        if (renderThread_.joinable()) {
            renderThread_.join();
        }
        if (codec_ != nullptr) {
            OH_VideoDecoder_Stop(codec_);
            OH_VideoDecoder_Destroy(codec_);
            codec_ = nullptr;
        }
        if (demuxer_ != nullptr) {
            OH_AVDemuxer_Destroy(demuxer_);
            demuxer_ = nullptr;
        }
        if (source_ != nullptr) {
            OH_AVSource_Destroy(source_);
            source_ = nullptr;
        }
        if (trackFormat_ != nullptr) {
            OH_AVFormat_Destroy(trackFormat_);
            trackFormat_ = nullptr;
        }
        if (window_ != nullptr) {
            OH_NativeWindow_DestroyNativeWindow(window_);
            window_ = nullptr;
        }
    }

    std::string Info() const
    {
        return codecName_ + "|" + mime_;
    }

private:
    static void OnNeedInputBuffer(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *userData)
    {
        auto *self = static_cast<SoftPlayer *>(userData);
        if (self == nullptr || self->released_) {
            return;
        }
        self->FeedInput(codec, index, buffer);
    }

    static void OnNewOutputBuffer(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *userData)
    {
        auto *self = static_cast<SoftPlayer *>(userData);
        if (self == nullptr || self->released_) {
            return;
        }
        OH_AVCodecBufferAttr attr;
        memset(&attr, 0, sizeof(attr));
        if (OH_AVBuffer_GetBufferAttr(buffer, &attr) != AV_ERR_OK) {
            OH_VideoDecoder_FreeOutputBuffer(codec, index);
            return;
        }
        if ((attr.flags & AVCODEC_BUFFER_FLAGS_EOS) != 0) {
            self->eosPending_ = true;
            OH_VideoDecoder_FreeOutputBuffer(codec, index);
            return;
        }
        {
            std::lock_guard<std::mutex> lock(self->queMutex_);
            self->renderQueue_.push_back(std::make_pair(index, attr.pts / 1000));
        }
        self->queCv_.notify_one();
    }

    void FeedInput(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer)
    {
        std::lock_guard<std::mutex> guard(demuxMutex_);
        if (pendingSeek_) {
            OH_AVDemuxer_SeekToTime(demuxer_, seekTarget_, SEEK_MODE_PREVIOUS_SYNC);
            pendingSeek_ = false;
        }
        if (eosReached_) {
            OH_AVCodecBufferAttr attr;
            memset(&attr, 0, sizeof(attr));
            attr.flags = AVCODEC_BUFFER_FLAGS_EOS;
            OH_AVBuffer_SetBufferAttr(buffer, &attr);
            OH_VideoDecoder_PushInputBuffer(codec, index);
            return;
        }
        OH_AVErrCode ret = OH_AVDemuxer_ReadSampleBuffer(demuxer_, static_cast<uint32_t>(trackIndex_), buffer);
        if (ret != AV_ERR_OK) {
            eosReached_ = true;
            OH_AVCodecBufferAttr attr;
            memset(&attr, 0, sizeof(attr));
            attr.flags = AVCODEC_BUFFER_FLAGS_EOS;
            OH_AVBuffer_SetBufferAttr(buffer, &attr);
        }
        OH_VideoDecoder_PushInputBuffer(codec, index);
    }

    void RenderLoop()
    {
        while (running_) {
            if (paused_) {
                std::this_thread::sleep_for(std::chrono::milliseconds(10));
                continue;
            }
            std::pair<uint32_t, int64_t> frame;
            bool has = false;
            {
                std::unique_lock<std::mutex> lock(queMutex_);
                if (renderQueue_.empty()) {
                    lock.unlock();
                    std::this_thread::sleep_for(std::chrono::milliseconds(2));
                    continue;
                }
                frame = renderQueue_.front();
                renderQueue_.pop_front();
                has = true;
            }
            if (!has || codec_ == nullptr) {
                continue;
            }
            int64_t now = clockMs_;
            if (firstFrame_) {
                firstFrame_ = false;
            }
            if (frame.second > now + 12) {
                // 还没到显示时间：先放回队列头，稍后再取
                {
                    std::lock_guard<std::mutex> lock(queMutex_);
                    renderQueue_.push_front(frame);
                }
                int64_t waitMs = frame.second - now;
                if (waitMs > 30) {
                    waitMs = 30;
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(waitMs > 0 ? waitMs : 1));
                continue;
            }
            if (frame.second < now - 150) {
                // 落后太多，跳帧
                OH_VideoDecoder_FreeOutputBuffer(codec_, frame.first);
                continue;
            }
            OH_VideoDecoder_RenderOutputBuffer(codec_, frame.first);
        }
        // 退出前清空队列，避免泄漏
        std::lock_guard<std::mutex> lock(queMutex_);
        while (!renderQueue_.empty() && codec_ != nullptr) {
            OH_VideoDecoder_FreeOutputBuffer(codec_, renderQueue_.front().first);
            renderQueue_.pop_front();
        }
    }

    OHNativeWindow *window_ = nullptr;
    OH_AVSource *source_ = nullptr;
    OH_AVDemuxer *demuxer_ = nullptr;
    OH_AVCodec *codec_ = nullptr;
    OH_AVFormat *trackFormat_ = nullptr;
    int32_t trackIndex_ = 0;
    std::string mime_;
    std::string codecName_;

    std::mutex demuxMutex_;
    std::mutex queMutex_;
    std::condition_variable queCv_;
    std::deque<std::pair<uint32_t, int64_t>> renderQueue_;
    std::thread renderThread_;

    std::atomic<bool> running_{false};
    std::atomic<bool> released_{false};
    std::atomic<bool> paused_{false};
    std::atomic<bool> eosReached_{false};
    std::atomic<bool> eosPending_{false};
    std::atomic<bool> pendingSeek_{false};
    std::atomic<bool> firstFrame_{true};
    std::atomic<int64_t> clockMs_{0};
    std::atomic<int64_t> seekTarget_{0};
    std::atomic<double> speed_{1.0};
};

std::mutex gMapMutex;
std::map<int32_t, SoftPlayer *> gPlayers;
int32_t gNextId = 1;

SoftPlayer *Find(int32_t id)
{
    std::lock_guard<std::mutex> lock(gMapMutex);
    auto it = gPlayers.find(id);
    return it == gPlayers.end() ? nullptr : it->second;
}

napi_value ThrowError(napi_env env, const char *msg)
{
    napi_throw_error(env, nullptr, msg);
    return nullptr;
}

std::string GetStringArg(napi_env env, napi_value value)
{
    size_t len = 0;
    napi_get_value_string_utf8(env, value, nullptr, 0, &len);
    if (len == 0) {
        return std::string();
    }
    std::string out(len, '\0');
    napi_get_value_string_utf8(env, value, &out[0], len + 1, &len);
    return out;
}

napi_value Create(napi_env env, napi_callback_info info)
{
    size_t argc = 5;
    napi_value args[5] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 5) {
        return ThrowError(env, "create requires 5 args");
    }
    std::string surfaceId = GetStringArg(env, args[0]);
    int32_t fd = 0;
    int64_t offset = 0;
    int64_t length = 0;
    bool preferSoftware = true;
    napi_get_value_int32(env, args[1], &fd);
    napi_get_value_int64(env, args[2], &offset);
    napi_get_value_int64(env, args[3], &length);
    napi_get_value_bool(env, args[4], &preferSoftware);

    auto *player = new SoftPlayer();
    int32_t ret = player->Init(surfaceId, fd, offset, length, preferSoftware);
    if (ret != 0) {
        player->Release();
        delete player;
        char buf[96] = {0};
        snprintf(buf, sizeof(buf), "soft decoder init failed code=%d", ret);
        return ThrowError(env, buf);
    }
    int32_t id = 0;
    {
        std::lock_guard<std::mutex> lock(gMapMutex);
        id = gNextId++;
        gPlayers[id] = player;
    }
    napi_value out = nullptr;
    napi_create_int32(env, id, &out);
    return out;
}

napi_value SetClock(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t id = 0;
    int64_t ms = 0;
    napi_get_value_int32(env, args[0], &id);
    napi_get_value_int64(env, args[1], &ms);
    SoftPlayer *p = Find(id);
    if (p != nullptr) {
        p->SetClock(ms);
    }
    return nullptr;
}

napi_value SetPaused(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t id = 0;
    bool paused = false;
    napi_get_value_int32(env, args[0], &id);
    napi_get_value_bool(env, args[1], &paused);
    SoftPlayer *p = Find(id);
    if (p != nullptr) {
        p->SetPaused(paused);
    }
    return nullptr;
}

napi_value Seek(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t id = 0;
    int64_t ms = 0;
    napi_get_value_int32(env, args[0], &id);
    napi_get_value_int64(env, args[1], &ms);
    SoftPlayer *p = Find(id);
    if (p != nullptr) {
        p->Seek(ms);
    }
    return nullptr;
}

napi_value Release(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t id = 0;
    napi_get_value_int32(env, args[0], &id);
    SoftPlayer *p = nullptr;
    {
        std::lock_guard<std::mutex> lock(gMapMutex);
        auto it = gPlayers.find(id);
        if (it != gPlayers.end()) {
            p = it->second;
            gPlayers.erase(it);
        }
    }
    if (p != nullptr) {
        p->Release();
        delete p;
    }
    return nullptr;
}

napi_value CodecInfo(napi_env env, napi_callback_info cbInfo)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, cbInfo, &argc, args, nullptr, nullptr);
    int32_t id = 0;
    napi_get_value_int32(env, args[0], &id);
    SoftPlayer *p = Find(id);
    std::string desc = p != nullptr ? p->Info() : std::string("none");
    napi_value out = nullptr;
    napi_create_string_utf8(env, desc.c_str(), desc.size(), &out);
    return out;
}

} // namespace

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"create", nullptr, Create, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setClock", nullptr, SetClock, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setPaused", nullptr, SetPaused, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"seek", nullptr, Seek, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"release", nullptr, Release, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"info", nullptr, CodecInfo, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module softPlayerModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "softplayer",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterSoftPlayerModule(void)
{
    napi_module_register(&softPlayerModule);
}
