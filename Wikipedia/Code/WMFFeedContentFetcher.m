#import <WMF/WMFFeedContentFetcher.h>
#import <WMF/WMFMantleJSONResponseSerializer.h>
#import <WMF/WMFFeedDayResponse.h>
#import <WMF/NSDateFormatter+WMFExtensions.h>
#import <WMF/WMFLogging.h>
#import <WMF/NSURL+WMFLinkParsing.h>
#import <WMF/NSError+WMFExtensions.h>
#import <WMF/WMFNetworkUtilities.h>
#import <WMF/NSString+WMFExtras.h>
#import <WMF/NSCalendar+WMFCommonCalendars.h>
#import <WMF/WMF-Swift.h>

NS_ASSUME_NONNULL_BEGIN

static const NSInteger WMFFeedContentFetcherMinimumMaxAge = 18000; // 5 minutes

@interface WMFFeedContentFetcher ()
@property (nonatomic, strong) WMFSession *session;
@property (nonatomic, strong) dispatch_queue_t serialQueue;
@end

@implementation WMFFeedContentFetcher

- (instancetype)init {
    self = [super init];
    if (self) {
        self.session = [WMFSession shared];
        NSString *queueID = [NSString stringWithFormat:@"org.wikipedia.feedcontentfetcher.accessQueue.%@", [[NSUUID UUID] UUIDString]];
        self.serialQueue = dispatch_queue_create([queueID cStringUsingEncoding:NSUTF8StringEncoding], DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

+ (NSURL *)feedContentURLForSiteURL:(NSURL *)siteURL onDate:(NSDate *)date {
    NSString *datePath = [[NSDateFormatter wmf_yearMonthDayPathDateFormatter] stringFromDate:date];

    NSString *path = [NSString stringWithFormat:@"/api/rest_v1/feed/featured/%@", datePath];

    return [siteURL wmf_URLWithPath:path isMobile:NO];
}

+ (NSRegularExpression *)cacheControlRegex {
    static NSRegularExpression *cacheControlRegex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSError *error = NULL;
        cacheControlRegex = [NSRegularExpression regularExpressionWithPattern:@"(?<=max-age=)\\d{2}"
                                                                      options:NSRegularExpressionCaseInsensitive
                                                                        error:&error];
        if (error) {
            DDLogError(@"Error creating cache control regex: %@", error);
        }
    });
    return cacheControlRegex;
}

- (void)fetchFeedContentForURL:(NSURL *)siteURL date:(NSDate *)date force:(BOOL)force failure:(WMFErrorHandler)failure success:(void (^)(WMFFeedDayResponse *feedDay))success {
    NSParameterAssert(siteURL);
    NSParameterAssert(date);
    dispatch_block_t genericFailure = ^{
        NSError *error = [NSError wmf_errorWithType:WMFErrorTypeInvalidRequestParameters
                                           userInfo:nil];
        failure(error);
    };
    if (siteURL == nil || date == nil) {
        genericFailure();
        return;
    }

    NSURL *url = [[self class] feedContentURLForSiteURL:siteURL onDate:date];
    [self.session getJSONDictionaryFromURL:url withQueryParameters:nil bodyParameters:nil ignoreCache:NO completionHandler:^(NSDictionary<NSString *,id> * _Nullable jsonDictionary, NSHTTPURLResponse * _Nullable response, NSError * _Nullable error) {
        if (error) {
            failure(error);
            return;
        }
        
        if (!force && response.statusCode == 304) {
            failure([NSError wmf_errorWithType:WMFErrorTypeNoNewData userInfo:nil]);
            return;
        }
        
        NSError *mantleError = nil;
        WMFFeedDayResponse *responseObject = [MTLJSONAdapter modelOfClass:[WMFFeedDayResponse class] fromJSONDictionary:jsonDictionary error:&mantleError];
        if (mantleError) {
            DDLogError(@"Error parsing feed day response: %@", mantleError);
            failure(mantleError);
            return;
        }
        
        if (![responseObject isKindOfClass:[WMFFeedDayResponse class]]) {
            failure([NSError wmf_errorWithType:WMFErrorTypeUnexpectedResponseType
                                      userInfo:nil]);
            
        } else {
            NSDictionary *headers = [response allHeaderFields];
            NSString *cacheControlHeader = headers[@"Cache-Control"];
            NSInteger maxAge = WMFFeedContentFetcherMinimumMaxAge;
            NSRegularExpression *regex = [WMFFeedContentFetcher cacheControlRegex];
            if (regex && cacheControlHeader.length > 0) {
                NSRange rangeOfFirstMatch = [regex rangeOfFirstMatchInString:cacheControlHeader options:0 range:NSMakeRange(0, [cacheControlHeader length])];
                if (rangeOfFirstMatch.location != NSNotFound) {
                    NSString *substringForFirstMatch = [cacheControlHeader substringWithRange:rangeOfFirstMatch];
                    maxAge = MAX([substringForFirstMatch intValue], WMFFeedContentFetcherMinimumMaxAge);
                }
            }
            responseObject.maxAge = maxAge;
            success(responseObject);
        }
    }];
}

- (void)fetchPageviewsForURL:(NSURL *)titleURL startDate:(NSDate *)startDate endDate:(NSDate *)endDate failure:(WMFErrorHandler)failure success:(WMFPageViewsHandler)success {
    NSParameterAssert(titleURL);

    NSString *title = [titleURL.wmf_titleWithUnderscores wmf_UTF8StringWithPercentEscapes];
    NSString *language = titleURL.wmf_language;
    NSString *domain = titleURL.wmf_domain;

    NSParameterAssert(title);
    NSParameterAssert(language);
    NSParameterAssert(domain);
    NSParameterAssert(startDate);
    NSParameterAssert(endDate);
    if (startDate == nil || endDate == nil || title == nil || language == nil || domain == nil) {
        NSError *error = [NSError wmf_errorWithType:WMFErrorTypeInvalidRequestParameters
                                           userInfo:nil];
        failure(error);
        return;
    }

    NSString *startDateString = [[NSDateFormatter wmf_englishUTCNonDelimitedYearMonthDayFormatter] stringFromDate:startDate];
    NSString *endDateString = [[NSDateFormatter wmf_englishUTCNonDelimitedYearMonthDayFormatter] stringFromDate:endDate];

    if (startDateString == nil || endDateString == nil) {
        DDLogError(@"Failed to format pageviews date URL component for dates: %@ %@", startDate, endDate);
        NSError *error = [NSError wmf_errorWithType:WMFErrorTypeInvalidRequestParameters
                                           userInfo:@{ WMFFailingRequestParametersUserInfoKey: @{@"start": startDate, @"end": endDate} }];
        failure(error);
        return;
    }

    NSString *path = [NSString stringWithFormat:@"/metrics/pageviews/per-article/%@.%@/all-access/user/%@/daily/%@/%@",
                                                language, domain, title, startDateString, endDateString];

    NSString *requestURLString = [WMFWikimediaRestAPIURLStringWithVersion(1) stringByAppendingString:path];

    NSURL *url = [NSURL URLWithString:requestURLString];

    NSCalendar *calendar = [NSCalendar wmf_utcGregorianCalendar];
    [self.session getJSONDictionaryFromURL:url withQueryParameters:nil bodyParameters:nil ignoreCache:NO completionHandler:^(NSDictionary<NSString *,id> * _Nullable responseObject, NSHTTPURLResponse * _Nullable response, NSError * _Nullable error) {
        if (error) {
            failure(error);
            return;
        }
        dispatch_async(self.serialQueue, ^{
            NSArray *items = responseObject[@"items"];
            if (![items isKindOfClass:[NSArray class]]) {
                failure([NSError wmf_errorWithType:WMFErrorTypeUnexpectedResponseType
                                          userInfo:nil]);
                return;
            }

            NSMutableDictionary *results = [NSMutableDictionary dictionaryWithCapacity:[items count]];
            for (id item in items) {
                if ([item isKindOfClass:[NSDictionary class]] && [item[@"views"] isKindOfClass:[NSNumber class]] && [item[@"timestamp"] isKindOfClass:[NSString class]]) {
                    NSDate *date = [[NSDateFormatter wmf_englishUTCNonDelimitedYearMonthDayHourFormatter] dateFromString:item[@"timestamp"]];
                    results[date] = item[@"views"];
                }
            }

            NSDate *date = startDate;

            while ([date compare:endDate] == NSOrderedAscending) {
                if (results[date]) {
                    break;
                }
                results[date] = @(0);
                date = [calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:date options:NSCalendarMatchStrictly];
            }

            success([results copy]);
        });
        }];
}

@end

NS_ASSUME_NONNULL_END
