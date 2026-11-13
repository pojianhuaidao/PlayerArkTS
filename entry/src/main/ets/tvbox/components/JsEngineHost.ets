/**
 * JsEngineHost - Hidden WebView component that hosts the JS execution engine
 * Uses data: URL to load bootstrap HTML directly as src
 */
import { webview } from '@kit.ArkWeb';
import { setWebController, getNativeBridge, getBootstrapDataUrl, onWebViewPageEnd } from '../api/JsEngine';

@Component
export struct JsEngineHost {
  private controller: webview.WebviewController = new webview.WebviewController();
  private dataUrl: string = getBootstrapDataUrl();

  aboutToAppear(): void {
    setWebController(this.controller);
    console.info('[JsEngineHost] aboutToAppear, dataUrl length: ' + this.dataUrl.length);
  }

  build() {
    Web({ src: this.dataUrl, controller: this.controller })
      .javaScriptAccess(true)
      .domStorageAccess(true)
      .fileAccess(true)
      .onlineImageAccess(true)
      .width('1vp')
      .height('1vp')
      .position({ x: -100, y: -100 })
      .onPageEnd(() => {
        console.info('[JsEngineHost] onPageEnd triggered');
        onWebViewPageEnd();
      })
      .onErrorReceive((event) => {
        console.error('[JsEngineHost] WebView error: ' + (event && event.error ? String(event.error.getErrorInfo()) : 'unknown'));
      })
      .onControllerAttached(() => {
        console.info('[JsEngineHost] Controller attached');
      })
      .javaScriptProxy({
        object: getNativeBridge(),
        name: 'NativeBridge',
        methodList: [
          'httpAsync', 'httpDone', 'httpResult',
          'joinUrl', 'pdfh', 'pd', 'pdfa', 'pdfla',
          'aesX', 'base64Encode', 'base64Decode', 'md5', 'log', 'setCallResult'
        ],
        controller: this.controller
      });
  }
}
