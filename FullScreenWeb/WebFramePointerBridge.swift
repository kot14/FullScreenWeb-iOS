import WebKit

/// JS injected into every frame (`forMainFrameOnly: false`).
/// Main frame receives native coords; hits on `<iframe>` are forwarded via `postMessage`
/// (works cross-origin). `video.play()` runs only inside the frame that owns the media.
enum WebFramePointerBridge {
    static let messageName = "fsBridge"

    static let userScriptSource = """
    (function() {
      if (window.__fsBridgeInstalled) return;
      window.__fsBridgeInstalled = true;

      var frameHref = '';
      try { frameHref = String(location.href || ''); } catch (e) { frameHref = '(opaque)'; }
      var isTop = false;
      try { isTop = (window === window.top); } catch (e) { isTop = false; }

      function prepare(v) {
        if (!v || v.__fsPrepared) return;
        v.__fsPrepared = true;
        try {
          v.setAttribute('playsinline', '');
          v.setAttribute('webkit-playsinline', '');
          v.playsInline = true;
          v.preload = v.preload || 'auto';
        } catch (e) {}
      }
      window.__fsPrepareMedia = prepare;

      function scan(root) {
        try {
          (root.querySelectorAll ? root.querySelectorAll('video,audio') : []).forEach(prepare);
        } catch (e) {}
      }
      scan(document);
      try {
        new MutationObserver(function(mutations) {
          mutations.forEach(function(m) {
            m.addedNodes.forEach(function(n) {
              if (n.nodeType !== 1) return;
              if (n.tagName === 'VIDEO' || n.tagName === 'AUDIO') prepare(n);
              else scan(n);
            });
          });
        }).observe(document.documentElement, { childList: true, subtree: true });
      } catch (e) {}

      function post(payload) {
        try {
          var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.fsBridge;
          if (h) h.postMessage(payload);
        } catch (e) {}
      }

      function mediaPayload(media) {
        var src = '';
        try {
          src = media.currentSrc || media.src || '';
          if (!src) {
            var s = media.querySelector && media.querySelector('source');
            if (s) src = s.src || '';
          }
        } catch (e) {}
        return {
          tag: media.tagName || '',
          src: src,
          paused: !!media.paused,
          currentTime: media.currentTime || 0
        };
      }

      function findMedia(el) {
        var n = el;
        while (n) {
          if (n.tagName === 'VIDEO' || n.tagName === 'AUDIO') return n;
          n = n.parentElement;
        }
        return null;
      }

      function classNameOf(el) {
        try {
          return (typeof el.className === 'string') ? el.className : '';
        } catch (e) { return ''; }
      }

      var lastUpTime = 0;
      var lastUpX = 0;
      var lastUpY = 0;

      function mouseOpts(x, y, down) {
        return {
          bubbles: true, cancelable: true, composed: true,
          clientX: x, clientY: y, view: window,
          buttons: down ? 1 : 0, button: 0
        };
      }

      function tryExitFullscreen() {
        var exited = false;
        var d = document;
        try {
          var fs = d.fullscreenElement || d.webkitFullscreenElement;
          if (fs) {
            if (d.exitFullscreen) { d.exitFullscreen(); exited = true; }
            else if (d.webkitExitFullscreen) { d.webkitExitFullscreen(); exited = true; }
          } else if (d.webkitIsFullScreen && d.webkitCancelFullScreen) {
            d.webkitCancelFullScreen();
            exited = true;
          }
          var videos = d.querySelectorAll ? d.querySelectorAll('video') : [];
          for (var i = 0; i < videos.length; i++) {
            var v = videos[i];
            try {
              if (v.webkitDisplayingFullscreen && v.webkitExitFullscreen) {
                v.webkitExitFullscreen();
                exited = true;
              }
            } catch (e) {}
          }
        } catch (e) {}
        return exited;
      }

      function isDoubleClick(x, y) {
        var now = Date.now();
        var dbl = (now - lastUpTime < 400)
          && Math.hypot(x - lastUpX, y - lastUpY) < 28;
        lastUpTime = now;
        lastUpX = x;
        lastUpY = y;
        return dbl;
      }

      function dispatchEvents(el, phase, x, y) {
        var opts = mouseOpts(x, y, phase === 'down');
        if (phase === 'down') {
          try {
            el.dispatchEvent(new PointerEvent('pointerdown', Object.assign({
              pointerId: 1, pointerType: 'mouse', isPrimary: true
            }, opts)));
          } catch (e) {}
          el.dispatchEvent(new MouseEvent('mousedown', opts));
          window.__fsCursorEl = el;
          return el;
        }
        if (phase === 'up') {
          var target = window.__fsCursorEl || el;
          window.__fsCursorEl = null;
          try {
            target.dispatchEvent(new PointerEvent('pointerup', Object.assign({
              pointerId: 1, pointerType: 'mouse', isPrimary: true
            }, opts)));
          } catch (e) {}
          target.dispatchEvent(new MouseEvent('mouseup', opts));
          target.dispatchEvent(new MouseEvent('click', opts));
          try { if (target.focus) target.focus(); } catch (e) {}
          return target;
        }
        if (phase === 'move') {
          el.dispatchEvent(new MouseEvent('mousemove', opts));
          return el;
        }
        return el;
      }

      function forwardToIFrame(iframe, phase, x, y) {
        var r = iframe.getBoundingClientRect();
        // Parent viewport → iframe content viewport (subtract border via clientLeft/Top).
        var lx = x - r.left - (iframe.clientLeft || 0);
        var ly = y - r.top - (iframe.clientTop || 0);
        try {
          iframe.contentWindow.postMessage({
            __fsPointer: true,
            phase: phase,
            x: lx,
            y: ly
          }, '*');
        } catch (e) {
          if (phase !== 'move') {
            post({
              type: 'forwardFailed',
              phase: phase,
              error: String(e && e.message ? e.message : e),
              frame: frameHref
            });
          }
          return;
        }
        if (phase !== 'move') {
          post({
            type: 'forwardIFrame',
            phase: phase,
            parentX: x,
            parentY: y,
            localX: lx,
            localY: ly,
            iframe: {
              left: r.left, top: r.top,
              width: r.width, height: r.height
            },
            frame: frameHref,
            isTop: isTop
          });
        }
      }

      function handlePointer(phase, x, y) {
        var el = null;
        try { el = document.elementFromPoint(x, y); } catch (e) {}
        if (!el) {
          if (phase !== 'move') {
            post({ type: 'miss', phase: phase, x: x, y: y, frame: frameHref, isTop: isTop });
          }
          return;
        }

        var tag = el.tagName || '';

        // Never read iframe DOM from parent (cross-origin). Forward coords instead.
        if (tag === 'IFRAME') {
          dispatchEvents(el, phase, x, y);
          forwardToIFrame(el, phase, x, y);
          return;
        }

        var target = dispatchEvents(el, phase, x, y);
        if (phase === 'move') return;

        // Double-click → ask native to dismiss WK media/element fullscreen.
        // JS exitFullscreen alone often no-ops for WebKit's out-of-window presentation.
        if (phase === 'up' && isDoubleClick(x, y)) {
          try {
            (target || el).dispatchEvent(new MouseEvent('dblclick', mouseOpts(x, y, false)));
          } catch (e) {}
          var jsExited = tryExitFullscreen();
          post({
            type: 'exitFullscreen',
            phase: phase,
            jsExited: jsExited,
            hitTag: tag,
            className: classNameOf(el),
            x: x, y: y,
            frame: frameHref,
            isTop: isTop
          });
          return;
        }

        // Do not call media.play()/pause() here — synthetic click already toggles
        // players; a second toggle looked like a double-click.
        var media = findMedia(target || el);
        if (media && phase === 'up') prepare(media);

        post({
          type: media ? 'media' : 'hit',
          phase: phase,
          action: null,
          playError: null,
          media: media ? mediaPayload(media) : null,
          hitTag: tag,
          className: classNameOf(el),
          x: x, y: y,
          frame: frameHref,
          isTop: isTop
        });
      }

      window.addEventListener('message', function(ev) {
        var d = ev.data;
        if (!d || d.__fsPointer !== true) return;
        if (d.phase === 'exitFullscreen') {
          var jsExited = tryExitFullscreen();
          post({ type: 'exitFullscreen', jsExited: jsExited, frame: frameHref, isTop: isTop });
          return;
        }
        if (typeof d.x !== 'number' || typeof d.y !== 'number') return;
        handlePointer(d.phase || 'up', d.x, d.y);
      }, false);

      // Native entry point (main-frame evaluateJavaScript only).
      window.__fsPointerEvent = function(phase, x, y) {
        handlePointer(phase, x, y);
      };
    })();
    """
}

/// Receives hit/media reports from every frame (including cross-origin iframes).
final class WebFramePointerBridgeHandler: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == WebFramePointerBridge.messageName else { return }
        guard let body = message.body as? [String: Any] else { return }

        let type = body["type"] as? String ?? "?"
        let phase = body["phase"] as? String
        let frame = body["frame"] as? String ?? ""
        let isTop = body["isTop"] as? Bool
        let hitTag = body["hitTag"] as? String
        let className = body["className"] as? String ?? ""
        let x = body["x"] as? Double
        let y = body["y"] as? Double

        switch type {
        case "exitFullscreen":
            let jsExited = body["jsExited"] as? Bool
            print("[FSWeb] exitFullscreen via dblclick jsExited=\(jsExited.map(String.init(describing:)) ?? "?") frame=\(short(frame))")
            // WK element/media fullscreen lives in a separate window — JS exit is not enough.
            webView?.closeAllMediaPresentations {
                print("[FSWeb] closeAllMediaPresentations done")
            }
        case "forwardIFrame":
            let lx = body["localX"] as? Double ?? 0
            let ly = body["localY"] as? Double ?? 0
            let px = body["parentX"] as? Double ?? 0
            let py = body["parentY"] as? Double ?? 0
            print("[FSWeb] iframe forward phase=\(phase ?? "?") parent=(\(fmt(px)),\(fmt(py))) → local=(\(fmt(lx)),\(fmt(ly))) frame=\(short(frame))")
        case "forwardFailed":
            print("[FSWeb] iframe forward FAILED: \(body["error"] ?? "") frame=\(short(frame))")
        case "miss":
            print("[FSWeb] miss phase=\(phase ?? "?") @ (\(fmt(x)),\(fmt(y))) frame=\(short(frame))")
        case "hit", "media":
            let topMark = (isTop == true) ? "top" : "iframe"
            print("[FSWeb] \(type) [\(topMark)] phase=\(phase ?? "?") <\(hitTag ?? "?") class=\"\(className)\"> @ (\(fmt(x)),\(fmt(y)))")
            if let media = body["media"] as? [String: Any] {
                let src = media["src"] as? String ?? ""
                let paused = media["paused"] as? Bool
                let time = media["currentTime"] as? Double
                let action = body["action"] as? String
                print("[FSWeb]   media <\(media["tag"] ?? "?")> action=\(action ?? "-") paused=\(paused.map(String.init(describing:)) ?? "?") t=\(time.map { String(format: "%.2f", $0) } ?? "?")")
                print("[FSWeb]   src=\(src.isEmpty ? "(empty)" : src)")
                if src.hasPrefix("blob:") {
                    print("[FSWeb]   NOTE: blob: — playback stays in this WKWebView frame")
                }
            }
            if let err = body["playError"] as? String, !err.isEmpty {
                print("[FSWeb]   playError=\(err)")
            }
            if #available(iOS 15.0, *) {
                webView?.setAllMediaPlaybackSuspended(false)
            }
        default:
            print("[FSWeb] bridge \(type): \(body)")
        }
    }

    private func fmt(_ value: Double?) -> String {
        guard let value else { return "?" }
        return String(format: "%.1f", value)
    }

    private func short(_ url: String) -> String {
        if url.count <= 80 { return url }
        return String(url.prefix(77)) + "..."
    }
}
