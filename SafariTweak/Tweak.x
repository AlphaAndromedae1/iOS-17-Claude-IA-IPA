// Claude iOS 17 Fix for Safari: the Claude Web app's iOS 17.3 style fix, applied to Safari.
//
// WebKit in iOS 17.3 crashes on parts of claude.ai's CSS (relative colours, :has() selectors; see
// Shared/style-fix.js). Loaded into Safari (and SafariViewService, which shows Safari views in
// other apps), this tweak adds the same two pieces the app uses to every web view Safari makes:
//   - a content rule list that stops WebKit loading style sheets from Claude's own servers on
//     Claude's sites, so it never parses the originals;
//   - Shared/style-fix.js at document start on those sites, which loads the sheets itself, renames
//     what crashes WebKit, and adds the corrected CSS to the page.
// Nothing happens on other sites: the rules only apply on Claude's domains, and the script returns
// straight away anywhere else.

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#import "StyleFixJS.h"

static NSString *const kMessageHandlerName = @"claudeWebStyleSheet";
static NSString *const kRuleListIdentifier = @"ClaudeWebSafariFix";
static NSString *const kLogPrefix = @"[ClaudeWebSafariFix]";

// Web views share user content controllers; each one is set up once and remembered (weakly).
static NSHashTable<WKUserContentController *> *configuredControllers;
static WKContentRuleList *ruleList;
static BOOL compilingRuleList;
static id<WKScriptMessageHandlerWithReply> styleSheetFetcher;

#pragma mark - What goes into the page

static BOOL IsClaudeHost(NSString *host) {
    host = host.lowercaseString;
    for (NSString *domain in @[@"claude.ai", @"claude.com", @"anthropic.com"]) {
        if ([host isEqualToString:domain] || [host hasSuffix:[@"." stringByAppendingString:domain]]) return YES;
    }
    return NO;
}

// style-fix.js, preceded by the host object it expects, and only on Claude's sites.
static NSString *ScriptSource(void) {
    static NSString *source;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *styleFix = [NSString stringWithUTF8String:kStyleFixJS];
        NSString *host = [NSString stringWithFormat:
            @"(function () {\n"
            @"  var handlers = window.webkit && window.webkit.messageHandlers;\n"
            @"  var native = handlers && handlers.%@;\n"
            @"  window.__claudeStyleFixHost = {\n"
            @"    fetchText: function (url) {\n"
            @"      if (!native) return Promise.reject(new Error(\"The tweak isn't listening\"));\n"
            @"      return native.postMessage({ url: url, userAgent: navigator.userAgent });\n"
            @"    },\n"
            @"    report: function (message) {\n"
            @"      if (message && message.failed) console.warn(\"[Claude iOS 17 Fix]\", message.failed, message.error);\n"
            @"    }\n"
            @"  };\n"
            @"})();\n", kMessageHandlerName];
        source = [NSString stringWithFormat:
            @"if (/(^|\\.)(claude\\.ai|claude\\.com|anthropic\\.com)$/i.test(location.hostname)) {\n%@\n%@\n}\n",
            host, styleFix];
    });
    return source;
}

static WKUserScript *MakeUserScript(void) {
    return [[WKUserScript alloc] initWithSource:ScriptSource()
                                  injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                               forMainFrameOnly:YES];
}

// Blocks style sheets from Claude's servers, only on pages from Claude's sites (if-domain is the
// page's domain). Matches StyleFixRules in the app.
static NSString *RuleListJSON(void) {
    NSMutableArray *rules = [NSMutableArray array];
    for (NSString *pattern in @[@"claude\\.ai", @"claude\\.com", @"anthropic\\.com"]) {
        [rules addObject:@{
            @"trigger": @{
                @"url-filter": [NSString stringWithFormat:@"^https?://([^/:]+\\.)?%@[:/]", pattern],
                @"resource-type": @[@"style-sheet"],
                @"if-domain": @[@"*claude.ai", @"*claude.com", @"*anthropic.com"],
            },
            @"action": @{@"type": @"block"},
        }];
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:rules options:0 error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

#pragma mark - Downloading style sheets the page can't read

// When the page isn't allowed to read a style sheet (no CORS headers), style-fix.js asks here.
// Only https files on Claude's own domains are fetched, with the page's cookies and user agent.
@interface ClaudeWebStyleSheetFetcher : NSObject <WKScriptMessageHandlerWithReply>
@end

@implementation ClaudeWebStyleSheetFetcher

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message
                 replyHandler:(void (^)(id reply, NSString *errorMessage))replyHandler {
    NSDictionary *body = [message.body isKindOfClass:NSDictionary.class] ? message.body : nil;
    NSString *address = [body[@"url"] isKindOfClass:NSString.class] ? body[@"url"] : nil;
    NSURL *url = address ? [NSURL URLWithString:address] : nil;
    if (!url || ![url.scheme.lowercaseString isEqualToString:@"https"] || !IsClaudeHost(url.host)) {
        replyHandler(nil, @"Only Claude's own style sheets can be fetched");
        return;
    }
    NSString *userAgent = [body[@"userAgent"] isKindOfClass:NSString.class] ? body[@"userAgent"] : nil;
    NSString *host = url.host.lowercaseString;

    WKHTTPCookieStore *cookieStore = message.webView.configuration.websiteDataStore.httpCookieStore;
    void (^fetch)(NSArray<NSHTTPCookie *> *) = ^(NSArray<NSHTTPCookie *> *cookies) {
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                               cachePolicy:NSURLRequestUseProtocolCachePolicy
                                                           timeoutInterval:30];
        [request setValue:@"text/css,*/*;q=0.1" forHTTPHeaderField:@"Accept"];
        if (userAgent.length) [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];
        NSMutableArray<NSHTTPCookie *> *matching = [NSMutableArray array];
        for (NSHTTPCookie *cookie in cookies) {
            NSString *domain = cookie.domain.lowercaseString;
            if ([domain hasPrefix:@"."]) domain = [domain substringFromIndex:1];
            if ([host isEqualToString:domain] || [host hasSuffix:[@"." stringByAppendingString:domain]]) {
                [matching addObject:cookie];
            }
        }
        [[NSHTTPCookie requestHeaderFieldsWithCookies:matching] enumerateKeysAndObjectsUsingBlock:^(NSString *field, NSString *value, BOOL *stop) {
            [request setValue:value forHTTPHeaderField:field];
        }];

        [[NSURLSession.sharedSession dataTaskWithRequest:request
                                       completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
            NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (text && status >= 200 && status < 300) {
                    replyHandler(text, nil);
                } else {
                    replyHandler(nil, error.localizedDescription ?: [NSString stringWithFormat:@"HTTP %ld", (long)status]);
                }
            });
        }] resume];
    };

    if (cookieStore) {
        [cookieStore getAllCookies:fetch];
    } else {
        fetch(@[]);
    }
}

@end

#pragma mark - Setting up Safari's web views

static void AddMessageHandler(WKUserContentController *controller) {
    @try {
        [controller addScriptMessageHandler:styleSheetFetcher contentWorld:WKContentWorld.pageWorld name:kMessageHandlerName];
    } @catch (NSException *exception) {
        // Already there: WebKit throws rather than adding a second handler with the same name.
    }
}

static void CompileRuleList(void) {
    if (ruleList || compilingRuleList) return;
    NSString *json = RuleListJSON();
    if (!json) return;
    compilingRuleList = YES;
    [WKContentRuleListStore.defaultStore compileContentRuleListForIdentifier:kRuleListIdentifier
                                                       encodedContentRuleList:json
                                                            completionHandler:^(WKContentRuleList *list, NSError *error) {
        compilingRuleList = NO;
        if (!list) {
            NSLog(@"%@ Couldn't compile the style sheet rules: %@", kLogPrefix, error);
            return;
        }
        ruleList = list;
        for (WKUserContentController *controller in configuredControllers) {
            [controller addContentRuleList:list];
        }
    }];
}

static void SetUpController(WKUserContentController *controller) {
    if (!controller || [configuredControllers containsObject:controller]) return;
    [configuredControllers addObject:controller];
    [controller addUserScript:MakeUserScript()];
    AddMessageHandler(controller);
    if (ruleList) {
        [controller addContentRuleList:ruleList];
    } else {
        CompileRuleList();  // added to this controller too when it's ready
    }
}

%hook WKWebView

- (instancetype)initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration *)configuration {
    SetUpController(configuration.userContentController);
    return %orig;
}

%end

// If Safari clears a controller's scripts, rules or handlers, put the fix's own back.
%hook WKUserContentController

- (void)removeAllUserScripts {
    %orig;
    if ([configuredControllers containsObject:self]) [self addUserScript:MakeUserScript()];
}

- (void)removeAllContentRuleLists {
    %orig;
    if (ruleList && [configuredControllers containsObject:self]) [self addContentRuleList:ruleList];
}

- (void)removeAllScriptMessageHandlers {
    %orig;
    if ([configuredControllers containsObject:self]) AddMessageHandler(self);
}

%end

%ctor {
    configuredControllers = [NSHashTable weakObjectsHashTable];
    styleSheetFetcher = [ClaudeWebStyleSheetFetcher new];
    // Compile early, so the rules are usually ready before Safari restores its tabs.
    dispatch_async(dispatch_get_main_queue(), ^{
        CompileRuleList();
    });
    NSLog(@"%@ Loaded into %@", kLogPrefix, NSBundle.mainBundle.bundleIdentifier);
}
