import Foundation
import WebKit

/// Safari-style content blocker for WKWebView (network + cosmetic rules).
enum AdBlocker {
    /// Bump when rule payloads change so the on-disk compiled cache is rebuilt.
    static let listIdentifier = "FullScreenWeb.AdBlock.v3"

    /// Compiles (or loads cached) rule list and attaches it to the controller.
    static func install(on controller: WKUserContentController, completion: ((Bool) -> Void)? = nil) {
        guard let store = WKContentRuleListStore.default() else {
            completion?(false)
            return
        }
        store.lookUpContentRuleList(forIdentifier: listIdentifier) { cached, _ in
            if let cached {
                DispatchQueue.main.async {
                    apply(cached, to: controller)
                    completion?(true)
                }
                return
            }

            store.compileContentRuleList(
                forIdentifier: listIdentifier,
                encodedContentRuleList: rulesJSON
            ) { list, error in
                DispatchQueue.main.async {
                    if let error {
                        print("[FSWeb] AdBlock compile failed: \(error.localizedDescription)")
                        completion?(false)
                        return
                    }
                    guard let list else {
                        completion?(false)
                        return
                    }
                    apply(list, to: controller)
                    completion?(true)
                }
            }
        }
    }

    static func uninstall(from controller: WKUserContentController) {
        controller.removeAllContentRuleLists()
    }

    /// Warm the compiled cache at launch so the first WebView gets rules sooner.
    static func prepare() {
        guard let store = WKContentRuleListStore.default() else { return }
        store.lookUpContentRuleList(forIdentifier: listIdentifier) { cached, _ in
            if cached != nil { return }
            store.compileContentRuleList(
                forIdentifier: listIdentifier,
                encodedContentRuleList: rulesJSON
            ) { _, error in
                if let error {
                    print("[FSWeb] AdBlock prepare failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Extra pass for dynamically injected ads after the page settles.
    /// Safe to call on every `didFinish` while ad block is enabled.
    static func injectCosmeticCleanup(into webView: WKWebView) {
        webView.evaluateJavaScript(cosmeticCleanupJS, completionHandler: nil)
    }

    // MARK: - Apply

    private static func apply(_ list: WKContentRuleList, to controller: WKUserContentController) {
        controller.removeAllContentRuleLists()
        controller.add(list)
    }

    // MARK: - Network hosts

    /// Domain / host regexes matched against the full resource URL.
    private static let blockedHostPatterns: [String] = [
        // Google Ads / DoubleClick / Analytics
        ".*doubleclick\\.net",
        ".*2mdn\\.net",
        ".*googlesyndication\\.com",
        ".*googleadservices\\.com",
        ".*pagead2\\.googlesyndication\\.com",
        ".*adservice\\.google\\.",
        ".*ads\\.google\\.com",
        ".*google-analytics\\.com",
        ".*googletagmanager\\.com",
        ".*googletagservices\\.com",
        ".*adsystems\\.google",
        ".*fundingchoicesmessages\\.google\\.com",
        ".*securepubads\\.g\\.doubleclick\\.net",
        ".*pagead\\.l\\.doubleclick\\.net",
        ".*ad\\.doubleclick\\.net",
        ".*static\\.doubleclick\\.net",
        ".*g\\.doubleclick\\.net",
        ".*googleads\\.g\\.doubleclick\\.net",
        ".*partner\\.googleadservices\\.com",
        ".*www\\.googleadservices\\.com",
        ".*adtrafficquality\\.google",
        ".*scorecardresearch\\.com",
        ".*imrworldwide\\.com",
        ".*nielsen\\.com.*\\/g\\.gif",

        // Meta / Facebook
        ".*facebook\\.com\\/tr",
        ".*facebook\\.com\\/privacy_sandbox",
        ".*facebook\\.net.*\\/tr",
        ".*connect\\.facebook\\.net.*\\/signals",
        ".*connect\\.facebook\\.net.*\\/fbevents",
        ".*pixel\\.facebook\\.com",
        ".*an\\.facebook\\.com",
        ".*ads\\.facebook\\.com",

        // Common ad / exchange / SSP
        ".*adnxs\\.com",
        ".*adsrvr\\.org",
        ".*adsafeprotected\\.com",
        ".*advertising\\.com",
        ".*adform\\.net",
        ".*adcolony\\.com",
        ".*admob\\.com",
        ".*ads-twitter\\.com",
        ".*static\\.ads-twitter\\.com",
        ".*ads-api\\.twitter\\.com",
        ".*amazon-adsystem\\.com",
        ".*aax\\.amazon-adsystem\\.com",
        ".*assoc-amazon\\.com",
        ".*analytics\\.yahoo\\.com",
        ".*ads\\.yahoo\\.com",
        ".*adtechus\\.com",
        ".*adtech\\.de",
        ".*bidswitch\\.net",
        ".*casalemedia\\.com",
        ".*chartbeat\\.com",
        ".*clicktale\\.net",
        ".*criteo\\.com",
        ".*criteo\\.net",
        ".*exelator\\.com",
        ".*hotjar\\.com",
        ".*media\\.net",
        ".*moatads\\.com",
        ".*outbrain\\.com",
        ".*outbrainimg\\.com",
        ".*pubmatic\\.com",
        ".*quantserve\\.com",
        ".*rubiconproject\\.com",
        ".*serving-sys\\.com",
        ".*taboola\\.com",
        ".*trc\\.taboola\\.com",
        ".*cdn\\.taboola\\.com",
        ".*tapad\\.com",
        ".*3lift\\.com",
        ".*yieldmo\\.com",
        ".*zeotap\\.com",
        ".*smartadserver\\.com",
        ".*openx\\.net",
        ".*openx\\.com",
        ".*lijit\\.com",
        ".*sovrn\\.com",
        ".*contextweb\\.com",
        ".*spotxchange\\.com",
        ".*spotx\\.tv",
        ".*teads\\.tv",
        ".*tremorhub\\.com",
        ".*ads\\.linkedin\\.com",
        ".*px\\.ads\\.linkedin\\.com",
        ".*snap\\.licdn\\.com",
        ".*ads\\.microsoft\\.com",
        ".*bingads\\.microsoft\\.com",
        ".*bat\\.bing\\.com",
        ".*ads\\.tiktok\\.com",
        ".*analytics\\.tiktok\\.com",
        ".*ads\\.reddit\\.com",
        ".*alb\\.reddit\\.com",
        ".*ads\\.pinterest\\.com",
        ".*ct\\.pinterest\\.com",
        ".*ads\\.snapchat\\.com",
        ".*sc-static\\.net.*\\/scevent",
        ".*tr\\.snapchat\\.com",

        // Mobile attribution / product analytics
        ".*branch\\.io",
        ".*appsflyer\\.com",
        ".*adjust\\.com",
        ".*mixpanel\\.com",
        ".*segment\\.io",
        ".*segment\\.com",
        ".*amplitude\\.com",
        ".*heap-api\\.com",
        ".*heapanalytics\\.com",
        ".*newrelic\\.com",
        ".*nr-data\\.net",
        ".*fullstory\\.com",
        ".*mouseflow\\.com",
        ".*crazyegg\\.com",
        ".*clarity\\.ms",
        ".*pingdom\\.net",
        ".*quora\\.com.*\\/qevents",

        // Adobe / Oracle / identity graphs
        ".*demdex\\.net",
        ".*everesttech\\.net",
        ".*omtrdc\\.net",
        ".*2o7\\.net",
        ".*bluekai\\.com",
        ".*krxd\\.net",
        ".*rlcdn\\.com",
        ".*mathtag\\.com",
        ".*agkn\\.com",
        ".*addthis\\.com",
        ".*addthisedge\\.com",
        ".*sharethis\\.com",
        ".*nexac\\.com",

        // Popunders / malware-ish ad junk
        ".*popads\\.net",
        ".*popcash\\.net",
        ".*propellerads\\.com",
        ".*propellerclick\\.com",
        ".*adsterra\\.com",
        ".*hilltopads\\.com",
        ".*clickadu\\.com",
        ".*juicyads\\.com",
        ".*exoclick\\.com",
        ".*trafficjunky\\.net",
        ".*tsyndicate\\.com",
        ".*adnium\\.com",
        ".*adcash\\.com",
        ".*zeroredirect",
        ".*onclickads\\.net",
        ".*onclickmega\\.com",

        // Ukrainian / CIS / regional
        ".*admixer\\.net",
        ".*admixer\\.co",
        ".*adfox\\.ru",
        ".*adfox\\.yandex",
        ".*yandex\\.ru\\/ads",
        ".*yandex\\.com\\/ads",
        ".*mc\\.yandex\\.ru",
        ".*mc\\.yandex\\.com",
        ".*an\\.yandex\\.ru",
        ".*an\\.yandex\\.com",
        ".*ads\\.vk\\.com",
        ".*ad\\.mail\\.ru",
        ".*top\\.mail\\.ru",
        ".*top-fwz1\\.mail\\.ru",
        ".*rs\\.mail\\.ru",
        ".*mgid\\.com",
        ".*marketgid\\.com",
        ".*adriver\\.ru",
        ".*buzzoola\\.com",
        ".*betweendigital\\.com",
        ".*hybrid\\.ai",
        ".*getintent\\.com",
        ".*otm-r\\.com",
        ".*adhigh\\.net",
        ".*directadvert\\.ru",
        ".*gnezdo\\.ru",
        ".*redtram\\.com",
        ".*tns-counter\\.ru",
        ".*begun\\.ru",
        ".*smi2\\.ru",
        ".*smi2\\.net",
        ".*lentainform\\.com",
        ".*relap\\.io",
        ".*ssp\\.rambler\\.ru",
        ".*target\\.my\\.com",
        ".*trk\\.mail\\.ru"
    ]

    /// Path / query patterns (usually third-party).
    private static let blockedPathPatterns: [String] = [
        ".*\\/pagead\\/",
        ".*\\/pagead2\\/",
        ".*\\/pcs\\/activeview",
        ".*\\/adservice",
        ".*\\/adsystem",
        ".*\\/adunit",
        ".*\\/ad-manager",
        ".*\\/admanager",
        ".*\\/adserve",
        ".*\\/adserver",
        ".*\\/adsystems",
        ".*\\/advertisement",
        ".*\\/advertising\\/",
        ".*\\/affiliate\\/pixel",
        ".*\\/beacon\\/ad",
        ".*\\/prebid",
        ".*\\/gpt\\/pubads",
        ".*\\/tag\\/js\\/gpt\\.js",
        ".*\\/securepubads",
        ".*[\\?&]adurl=",
        ".*[\\?&]ad_type=",
        ".*[\\?&]adtype=",
        ".*[\\?&]adunit=",
        ".*[\\?&]google_ad_",
        ".*\\/ads\\.js",
        ".*\\/ads\\.min\\.js",
        ".*\\/ad\\.js",
        ".*\\/adframe",
        ".*\\/adframe\\.",
        ".*\\/adsframe",
        ".*\\/pixel\\.gif",
        ".*\\/pixel\\.png",
        ".*\\/1x1\\.gif",
        ".*\\/tracking\\/ad",
        ".*\\/collect\\?.*ad"
    ]

    // MARK: - Cosmetic CSS

    private static let hideSelectorGroups: [[String]] = [
        [
            "[id*='google_ads']",
            "[id*='google_ad']",
            "[id*='GoogleAd']",
            "[class*='google-ad']",
            "[class*='GoogleActiveView']",
            "[class*='adsbygoogle']",
            "ins.adsbygoogle",
            "iframe[id*='google_ads']",
            "iframe[src*='doubleclick']",
            "iframe[src*='googlesyndication']",
            "iframe[src*='googletagmanager']",
            "iframe[name*='google_ads']",
            "[data-ad-slot]",
            "[data-ad-client]",
            "[data-ad-status]",
            "[data-google-query-id]",
            "[data-ad-unit]",
            "[aria-label='Advertisement']",
            "[aria-label='Ads']"
        ],
        [
            "[id*='ad-container']",
            "[id*='ad_container']",
            "[id*='adcontainer']",
            "[class*='ad-container']",
            "[class*='ad_container']",
            "[class*='ad-banner']",
            "[class*='ad_banner']",
            "[class*='ad-slot']",
            "[class*='ad_slot']",
            "[class*='adslot']",
            "[class*='ad-wrapper']",
            "[class*='adWrapper']",
            "[class*='adsbox']",
            "[class*='ads-box']",
            "[class*='advertisement']",
            ".advertisement",
            ".advert",
            "#advertisement",
            "[id^='ad-']",
            "[id^='ads-']"
        ],
        [
            "[class*='sponsored-content']",
            "[class*='sponsored_content']",
            "[class*='sponsor-unit']",
            "[class*='taboola']",
            "[id*='taboola']",
            "[class*='outbrain']",
            "[id*='outbrain']",
            "[class*='mgid']",
            "[id*='mgid']",
            "[class*='yandex_ad']",
            "[class*='yandex-ad']",
            "[id*='yandex_ad']",
            "[id*='adfox']",
            "[class*='adfox']",
            "[class*='promo-ad']",
            "[class*='native-ad']",
            "[class*='native_ad']",
            "div[id*='div-gpt-ad']",
            "div[id^='gpt_unit']"
        ]
    ]

    // MARK: - Rules JSON

    private static let rulesJSON: String = {
        var rules: [[String: Any]] = []

        for pattern in blockedHostPatterns {
            rules.append([
                "trigger": [
                    "url-filter": pattern,
                    "load-type": ["third-party", "first-party"]
                ],
                "action": ["type": "block"]
            ])
        }

        for pattern in blockedPathPatterns {
            rules.append([
                "trigger": [
                    "url-filter": pattern,
                    "load-type": ["third-party"]
                ],
                "action": ["type": "block"]
            ])
        }

        for group in hideSelectorGroups {
            rules.append([
                "trigger": ["url-filter": ".*"],
                "action": [
                    "type": "css-display-none",
                    "selector": group.joined(separator: ", ")
                ]
            ])
        }

        guard let data = try? JSONSerialization.data(withJSONObject: rules, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }()

    // MARK: - Cosmetic JS

    /// Removes leftover ad iframes / empty GPT slots injected after first paint.
    private static let cosmeticCleanupJS = #"""
    (function () {
      if (window.__fsAdBlockCleanup) return;
      window.__fsAdBlockCleanup = true;

      var HOST_RE = /(doubleclick|googlesyndication|googleadservices|googletagservices|pagead|adnxs|adsrvr|criteo|taboola|outbrain|mgid|adfox|yandex\.(ru|com)\/ads|facebook\.com\/tr|amazon-adsystem|moatads|scorecardresearch|advertising\.com)/i;
      var NODE_RE = /(^|[-_])(ad|ads|advert|advertisement|sponsor|sponsored|taboola|outbrain|mgid|adfox|gpt-ad|adsbygoogle)([-_]|$)/i;

      function looksLikeAd(el) {
        if (!el || el.nodeType !== 1) return false;
        if (el.closest && el.closest('main article, [role="main"] article, header nav, footer')) {
          // Still allow clear ad markers inside articles (native ads).
        }
        var id = el.id || '';
        var cls = (typeof el.className === 'string' ? el.className : '') || '';
        var tag = (el.tagName || '').toLowerCase();
        if (NODE_RE.test(id) || NODE_RE.test(cls)) return true;
        if (el.getAttribute && (el.getAttribute('data-ad-slot') || el.getAttribute('data-ad-client') || el.getAttribute('data-google-query-id'))) return true;
        if (tag === 'iframe' || tag === 'img' || tag === 'script') {
          var src = el.src || el.getAttribute('data-src') || '';
          if (HOST_RE.test(src)) return true;
        }
        if (tag === 'ins' && (cls.indexOf('adsbygoogle') !== -1)) return true;
        return false;
      }

      function scrub(root) {
        var scope = root && root.querySelectorAll ? root : document;
        var nodes = scope.querySelectorAll('iframe, ins.adsbygoogle, [data-ad-slot], [data-google-query-id], [id*="div-gpt-ad"], [id*="google_ads"], [class*="adsbygoogle"]');
        for (var i = 0; i < nodes.length; i++) {
          var n = nodes[i];
          if (looksLikeAd(n)) {
            n.style.setProperty('display', 'none', 'important');
            n.setAttribute('hidden', '');
          }
        }
      }

      scrub(document);
      var obs = new MutationObserver(function (mutations) {
        for (var i = 0; i < mutations.length; i++) {
          var m = mutations[i];
          for (var j = 0; j < m.addedNodes.length; j++) {
            var node = m.addedNodes[j];
            if (looksLikeAd(node)) {
              node.style && node.style.setProperty('display', 'none', 'important');
            } else if (node.querySelectorAll) {
              scrub(node);
            }
          }
        }
      });
      if (document.documentElement) {
        obs.observe(document.documentElement, { childList: true, subtree: true });
      }
      setTimeout(function () { scrub(document); }, 1200);
      setTimeout(function () { scrub(document); }, 3500);
    })();
    """#
}
