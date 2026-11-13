cmake_minimum_required(VERSION 3.5.0)
project(softplayer)

set(CMAKE_CXX_STANDARD 17)
set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

include_directories(${NATIVERENDER_ROOT_PATH})

# 规避新版 hvigor 将 CMAKE_LIBRARY_OUTPUT_DIRECTORY 指到最终 obj 目录导致的“同路径硬链/复制”失败
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}")
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY_DEBUG "${CMAKE_CURRENT_BINARY_DIR}")
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY_RELEASE "${CMAKE_CURRENT_BINARY_DIR}")

add_library(softplayer SHARED softplayer.cpp)

target_link_libraries(softplayer PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    libnative_media_codecbase.so
    libnative_media_core.so
    libnative_media_vdec.so
    libnative_media_avdemuxer.so
    libnative_media_avsource.so
    libnative_window.so
)
