//
//  MTTiVo.m
//  cTiVo
//
//  Created by Scott Buchanan on 1/5/13.
//  Copyright (c) 2013 Scott Buchanan. All rights reserved.
//

#import "MTTiVo.h"
#import "MTTivoRPC.h"
#import "MTTiVoShow.h"
#import "MTDownload.h"
#import "NSString+HTML.h"
#import "MTTiVoManager.h"
#import "NSNotificationCenter+Threads.h"
#import "NSArray+Map.h"

#define kMTStringType 0
#define kMTBoolType 1
#define kMTNumberType 2
#define kMTDateType 3

#define kMTValue @"KeyValue"
#define kMTType @"KeyType"

//no more than 128 at a time
#define kMTNumberShowToGet 50
#define kMTNumberShowToGetFirst 15


@interface MTTiVo ()
{
    BOOL volatile isConnecting, managingDownloads, firstUpdate, cancelRefresh;
    NSMutableData *urlData;
    NSMutableArray *newShows;
    SCNetworkReachabilityContext reachabilityContext;
    int totalItemsOnTivo;
    int lastChangeDate;
    int itemStart;
    int itemCount;
    int numAddedThisBatch; //should be itemCount minus duplicates
    int authenticationTries;
    BOOL parsingShow, gettingContent, gettingDetails, gettingIcon;
    NSMutableString *element;
    MTTiVoShow *currentShow;
    NSDictionary *elementToPropertyMap;
    NSMutableDictionary *previousShowList;

}

@property (atomic, assign) BOOL oneBatch;
@property (nonatomic, strong) NSMutableArray<NSString *> * addedShows;
@property (nonatomic, strong) NSMutableArray<NSNumber *> * addedShowIndices;

@property (nonatomic, strong) NSDate *networkAvailability;
@property (nonatomic, strong) NSOperationQueue *opsQueue;
@property (nonatomic, strong) NSURLConnection *showURLConnection;
@property (nonatomic, strong) 	NSDate *currentNPLStarted;

@property SCNetworkReachabilityRef reachability;
@property (nonatomic, readonly) NSArray *downloadQueue;
@property (nonatomic, strong) MTTivoRPC * myRPC;
@property (atomic, strong) NSMutableDictionary <NSString *, MTTiVoShow *> * rpcIDs;

@end

@implementation MTTiVo
@synthesize enabled = _enabled;


__DDLOGHERE__

+(MTTiVo *)tiVoWithTiVo:(MTNetService *)tiVo
     withOperationQueue:(NSOperationQueue *)queue
       withSerialNumber:(NSString *)TSN {
    MTTiVo *thisTiVo = [[MTTiVo alloc] initWithTivo:tiVo withOperationQueue:(NSOperationQueue *)queue manual:NO withID:(int)0 withSerialNumber:TSN ];
    DDLogVerbose(@"Checking Enabled for %@", self);
    for (NSDictionary *description in tiVoManager.savedTiVos) {
        if ([description[kMTTiVoUserName] isEqualTo:thisTiVo.tiVo.name]) {
            thisTiVo.tiVoSerialNumber = description[kMTTiVoTSN];
            thisTiVo.enabled = [description[kMTTiVoEnabled] boolValue];
            if ((description[kMTTiVoMediaKey])  && ![description[kMTTiVoMediaKey] isEqualTo:kMTTiVoNullKey]) {
                thisTiVo.mediaKey = description[kMTTiVoMediaKey];
            }
            DDLogDetail(@"%@ is%@ Enabled", thisTiVo.tiVo.name,thisTiVo.enabled ? @"": @" not");
            return thisTiVo;
        }
    }
    thisTiVo.enabled = YES;
    DDLogMajor(@"First time seeing %@ (previous: %@)",thisTiVo, [tiVoManager.savedTiVos maskMediaKeys]);
    return thisTiVo;
}

+(MTTiVo *)manualTiVoWithDescription:(NSDictionary *)description withOperationQueue:(NSOperationQueue *)queue {
    //recently added RPC, so shouldn't fail if it's missing, but default to 1413 instead.  Could check in future.
    if (![description[kMTTiVoUserPort]    intValue] ||
        ![description[kMTTiVoUserPortSSL] intValue] ||
        ![description[kMTTiVoUserName]    length] ||
        ![description[kMTTiVoIPAddress]   length]  ) {
        return nil;
    }
    MTNetService *tiVo = [MTNetService new];
    tiVo.userPortSSL = (short)[description[kMTTiVoUserPortSSL] intValue];
    tiVo.userPortRPC = (short)[description[kMTTiVoUserPortRPC] ?: @1413 intValue];
    tiVo.userPort = (short)[description[kMTTiVoUserPort] intValue];
    tiVo.userName = description[kMTTiVoUserName];
    tiVo.iPAddress = description[kMTTiVoIPAddress];
    MTTiVo *thisTiVo = [[MTTiVo alloc] initWithTivo:tiVo withOperationQueue:queue manual:YES withID:[description[kMTTiVoID] intValue] withSerialNumber:description[kMTTiVoTSN]];
    if ((description[kMTTiVoMediaKey])  && ![description[kMTTiVoMediaKey] isEqualTo:kMTTiVoNullKey]) {
        thisTiVo.mediaKey = description[kMTTiVoMediaKey];
    }
    if ([tiVoManager duplicateTiVoFor:thisTiVo]) {
        thisTiVo.enabled = NO;
        return nil;
    }
    thisTiVo.enabled = YES;
    return thisTiVo;
}
	
-(id)init
{
	self = [super init];
	if (self) {
		self.shows = [NSArray array];
		urlData = [NSMutableData new];
		newShows = [NSMutableArray new];
		_tiVo = nil;
		previousShowList = nil;
		self.showURLConnection = nil;
		_mediaKey = @"";
		isConnecting = NO;
        managingDownloads = NO;
        _manualTiVo = NO;
		firstUpdate = YES;
        _enabled = NO;
        _storeMediaKeyInKeychain = NO;
        itemStart = 0;
        itemCount = 50;
        reachabilityContext.version = 0;
        reachabilityContext.info = (__bridge void *)(self);
        reachabilityContext.retain = NULL;
        reachabilityContext.release = NULL;
        reachabilityContext.copyDescription = NULL;
        elementToPropertyMap = @{
            @"Title" :          @{kMTValue : @"seriesTitle",      kMTType : @(kMTStringType)},
            @"EpisodeTitle" :   @{kMTValue : @"episodeTitle",     kMTType : @(kMTStringType)},
            @"CopyProtected" :  @{kMTValue : @"protectedShow",    kMTType : @(kMTBoolType)},
            @"InProgress" :     @{kMTValue : @"inProgress",       kMTType : @(kMTBoolType)},
            @"SourceSize" :     @{kMTValue : @"fileSize",         kMTType : @(kMTNumberType)},
            @"Duration" :       @{kMTValue : @"showLengthString", kMTType : @(kMTStringType)},
            @"CaptureDate" :    @{kMTValue : @"showDate",         kMTType : @(kMTDateType)},
            @"Description" :    @{kMTValue : @"showDescription",  kMTType : @(kMTStringType)},
            @"SourceChannel" :  @{kMTValue : @"channelString",    kMTType : @(kMTStringType)},
            @"SourceStation" :  @{kMTValue : @"stationCallsign",  kMTType : @(kMTStringType)},
            @"HighDefinition" : @{kMTValue : @"isHD",             kMTType : @(kMTBoolType)},
            @"ProgramId" :      @{kMTValue : @"programId",        kMTType : @(kMTStringType)},
            @"SeriesId" :       @{kMTValue : @"seriesId",         kMTType : @(kMTStringType)},
            @"TvRating" :       @{kMTValue : @"tvRating",         kMTType : @(kMTNumberType)},
            @"MpaaRating" :     @{kMTValue : @"mpaaRating",       kMTType : @(kMTNumberType)},
            @"SourceType" :     @{kMTValue : @"sourceType",       kMTType : @(kMTStringType)},
            @"IdGuideSource" :  @{kMTValue : @"idGuidSource",     kMTType : @(kMTStringType)}};
		elementToPropertyMap = [[NSDictionary alloc] initWithDictionary:elementToPropertyMap];
		_currentNPLStarted = nil;
		_lastDownloadEnded = [NSDate dateWithTimeIntervalSince1970:0];
		_manualTiVoID = -1;
        self.rpcIDs = [NSMutableDictionary dictionary];
	}
	return self;
	
}

-(id) initWithTivo:(MTNetService *)tiVo withOperationQueue:(NSOperationQueue *)queue manual:(BOOL)isManual withID:(int)manualTiVoID withSerialNumber:(NSString *)TSN {
	self = [self init];
	if (self) {
		self.tiVo = tiVo;
        _manualTiVo = isManual;
        self.manualTiVoID = manualTiVoID;
		self.opsQueue = queue;
        _tiVoSerialNumber = TSN;
        DDLogMajor(@"testing reachability for tivo %@ with address %@",self.tiVo.name, self.tiVo.addresses[0]);
        if (isManual) {
            _reachability = SCNetworkReachabilityCreateWithName(kCFAllocatorDefault, [self.tiVo.iPAddress UTF8String]);
        } else {
            _reachability = SCNetworkReachabilityCreateWithAddress(NULL, [self.tiVo.addresses[0] bytes]);
        }
		self.networkAvailability = [NSDate date];
		BOOL didSchedule = NO;
		if (_reachability) {
			SCNetworkReachabilitySetCallback(_reachability, tivoNetworkCallback, &reachabilityContext);
			didSchedule = SCNetworkReachabilityScheduleWithRunLoop(_reachability, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
		}
		_isReachable = didSchedule;
		if (!_isReachable) DDLogReport(@"Failed to schedule reachability for tivo %@", _tiVo.name);
		[self performSelectorOnMainThread:@selector(getMediaKey) withObject:nil waitUntilDone:YES];
		[self setupNotifications];
	}
	return self;
}

void tivoNetworkCallback    (SCNetworkReachabilityRef target,
							 SCNetworkReachabilityFlags flags,
							 void *info)
{
    MTTiVo *thisTivo = (__bridge MTTiVo *)info;
    BOOL isReachable = ((flags & kSCNetworkFlagsReachable) != 0);
    BOOL needsConnection = ((flags & kSCNetworkFlagsConnectionRequired) != 0);

    thisTivo.isReachable = isReachable && !needsConnection ;
    DDLogCReport(@"Tivo %@ is now %@", thisTivo.tiVo.name, thisTivo.isReachable ? @"online" : @"offline");
    if (thisTivo.isReachable) {
		thisTivo.networkAvailability = [NSDate date];
		[NSObject cancelPreviousPerformRequestsWithTarget:thisTivo selector:@selector(manageDownloads:) object:thisTivo];
		[thisTivo performSelector:@selector(manageDownloads:) withObject:thisTivo afterDelay:kMTTiVoAccessDelay+2];
        [thisTivo scheduleNextUpdateAfterDelay: kMTTiVoAccessDelay];
        [thisTivo.myRPC launchServer];
	} 
    [NSNotificationCenter postNotificationNameOnMainThread: kMTNotificationNetworkChanged object:nil];
}

-(void)setupNotifications
{
	NSNotificationCenter *defaultCenter = [NSNotificationCenter defaultCenter];
	[defaultCenter addObserver:self selector:@selector(manageDownloads:) name:kMTNotificationDownloadQueueUpdated object:nil];
	[defaultCenter addObserver:self selector:@selector(manageDownloads:) name:kMTNotificationTransferDidFinish object:nil];
	[defaultCenter addObserver:self selector:@selector(manageDownloads:) name:kMTNotificationDecryptDidFinish object:nil];

}

-(void) saveLastLoadTime:(NSDate *) newDate{
	if (!newDate) return;
    if (!self.tiVo.name.length) return;
	NSDate * currentDate = tiVoManager.lastLoadedTivoTimes[self.tiVo.name];

	if (!currentDate || [newDate isGreaterThan: currentDate]) {
		tiVoManager.lastLoadedTivoTimes[self.tiVo.name] = newDate;
	}

}

-(NSString * ) description
{
    if (self.manualTiVo) {
        return [NSString stringWithFormat:@"%@ (%@:%hd/%hd/%hd) %@",
            self.tiVo.name,
            self.tiVo.iPAddress,
            self.tiVo.userPort,
            self.tiVo.userPortSSL,
            self.tiVo.userPortRPC,
            self.enabled ? @"enabled": @""
            ];
    } else {
		return [self.tiVo.name stringByAppendingString: self.enabled ? @" enabled": @""];
    }
}

-(void)setEnabled:(BOOL) enabled {
    if (enabled && [tiVoManager duplicateTiVoFor:self]) {
        enabled = NO;
        [tiVoManager updateTiVoDefaults:self];
    }
    if (enabled && !self.myRPC) {
        if (self.supportsRPC) {
            int port = self.manualTiVo ? self.tiVo.userPortRPC : 1413;
            self.myRPC = [[MTTivoRPC alloc] initServer:self.tiVo.hostName tsn:self.tiVoSerialNumber onPort: port andMAK:self.mediaKey forDelegate:self];
        }
    } else if (!enabled && self.myRPC){
        [self.myRPC stopServer];
        self.myRPC = nil;
    }
    @synchronized (self) {
        if (enabled == _enabled) return;
        _enabled = enabled;
    }
    [tiVoManager updateTiVoDefaults:self];
}

-(BOOL) enabled {
    @synchronized (self) {
        return _enabled;
    }
}

-(void) setTiVoSerialNumber:(NSString *)TSN {
    if ([TSN hasPrefix:@"tsn:"]) {
        TSN = [TSN substringWithRange:NSMakeRange(4, TSN.length-4)];
    }
    if (TSN.length == 0) return;
    if ([TSN isEqualToString:_tiVoSerialNumber]) return;
    _tiVoSerialNumber = TSN;
    if (self.enabled && [tiVoManager duplicateTiVoFor:self]) {
        self.enabled = NO;
    } else {
        [tiVoManager updateTiVoDefaults:self];
    }
}

-(NSDictionary *)descriptionDictionary
{
    NSDictionary *retValue = nil;
    if (_manualTiVo) {
        retValue = @{kMTTiVoManualTiVo :   @YES,
                     kMTTiVoUserName :      self.tiVo.name,
                     kMTTiVoUserPort :    @(self.tiVo.userPort),
                     kMTTiVoUserPortSSL : @(self.tiVo.userPortSSL),
                     kMTTiVoTSN :           self.tiVoSerialNumber ?: @"",
                     kMTTiVoUserPortRPC : @(self.tiVo.userPortRPC),
                     kMTTiVoIPAddress :     self.tiVo.iPAddress,
                     kMTTiVoEnabled :     @(self.enabled),
                     kMTTiVoID :          @(self.manualTiVoID),
                     kMTTiVoMediaKey :      self.mediaKey
                     };
    } else {
        retValue = @{kMTTiVoManualTiVo :   @NO,
                     kMTTiVoUserName :      self.tiVo.name,
                     kMTTiVoTSN :           self.tiVoSerialNumber ?: @"",
                     kMTTiVoEnabled :     @(self.enabled),
                     kMTTiVoMediaKey :      self.mediaKey
                     };
    }
    return retValue;
}

-(void) updateWithDescription:(NSDictionary *) newTiVo {
    BOOL shouldUpdate = NO;
    BOOL newEnabled = ((NSNumber *) newTiVo[kMTTiVoEnabled]).boolValue;

    if (self.manualTiVo) {
        BOOL rpcChanged = [self.tiVo.iPAddress caseInsensitiveCompare:newTiVo[kMTTiVoIPAddress]] != NSOrderedSame ||
                          self.tiVo.userPortRPC != [newTiVo[kMTTiVoUserPortRPC] intValue];
        if (rpcChanged ||
            [self.tiVo.userName  compare:newTiVo[kMTTiVoUserName]] != NSOrderedSame ||
            self.tiVo.userPort != [newTiVo[kMTTiVoUserPort] intValue] ||
            self.tiVo.userPortSSL != [newTiVo[kMTTiVoUserPortSSL] intValue]
           ) { // If there's a change then edit it and update
            self.tiVo.iPAddress = newTiVo[kMTTiVoIPAddress];
            self.tiVo.userName = newTiVo[kMTTiVoUserName];
            self.tiVo.userPort = (short)[newTiVo[kMTTiVoUserPort] intValue];
            self.tiVo.userPortSSL = (short)[newTiVo[kMTTiVoUserPortSSL] intValue];
            self.tiVo.userPortRPC = (short)[newTiVo[kMTTiVoUserPortRPC] intValue];
            shouldUpdate = YES;
            if (rpcChanged) self.myRPC = nil; //will be restarted by "enabled"
        }
    }

    if ((newTiVo[kMTTiVoEnabled]  && self.enabled != newEnabled) ||
        (newTiVo[kMTTiVoTSN]      && ! [newTiVo[kMTTiVoTSN]      isEqualToString: self.tiVoSerialNumber]) ||
        (newTiVo[kMTTiVoMediaKey] && ! [newTiVo[kMTTiVoMediaKey] isEqualToString: self.mediaKey] && ![newTiVo[kMTTiVoMediaKey] isEqualTo:kMTTiVoNullKey])) {
        self.tiVoSerialNumber = (NSString *)newTiVo[kMTTiVoTSN];  //must be after enabled
        self.mediaKey = newTiVo[kMTTiVoMediaKey];
        shouldUpdate = YES;
    }
    self.enabled = newEnabled;

    if (shouldUpdate ) {
        DDLogDetail(@"Updated  TiVo %@ with %@",self, [newTiVo maskMediaKeys]);
       //Turn off label in UI
        [[NSNotificationCenter defaultCenter] postNotificationName:kMTNotificationTiVoUpdated object:self];
        //RE-update shows
        if (newEnabled) [self scheduleNextUpdateAfterDelay:0];
    }
}

-(void)getMediaKey
{
	DDLogDetail(@"Getting media key for %@", self);
    BOOL foundMediaKey = NO;
    NSArray *savedTiVos = tiVoManager.savedTiVos;
    if (savedTiVos.count == 0) {
        DDLogDetail(@"No Media Key to Crib");
        return;
    }

    if (savedTiVos[0][kMTTiVoMediaKey] && ![savedTiVos[0][kMTTiVoMediaKey] isEqualToString:kMTTiVoNullKey]) self.mediaKey = savedTiVos[0][kMTTiVoMediaKey];
    
    for (NSDictionary *tiVo in savedTiVos) {
        if ([tiVo[kMTTiVoUserName] isEqual:self.tiVo.name] && ![tiVo[kMTTiVoMediaKey] isEqual:kMTTiVoNullKey] && [tiVo[kMTTiVoMediaKey] length] > 0) {
            self.mediaKey = tiVo[kMTTiVoMediaKey];
            foundMediaKey = YES;
        }
    }
    if (!foundMediaKey) {
        //Need to update defaults
        [tiVoManager performSelectorOnMainThread:@selector(updateTiVoDefaults:) withObject:self waitUntilDone:YES];
    }
}

#pragma mark - RPC switchboard

-(void) receivedRPCData:(MTRPCData *)rpcData {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.rpcIDs[rpcData.rpcID].rpcData = rpcData;
    });
}

-(MTRPCData *) registerRPCforShow: (MTTiVoShow *) show  {
    NSString * rpcKey = [NSString stringWithFormat:@"%@|%@",self.tiVo.hostName, show.idString];
    [self.rpcIDs setObject:show forKey:rpcKey ];
    return [show.tiVo rpcDataForID:show.idString];
}

-(void) tivoReportsNewShows:(NSMutableArray<NSString *> *)addedShows
              atTiVoIndices: (NSMutableArray <NSNumber *> *) addedShowIndices
            andDeletedShows:(NSMutableDictionary < NSString *, MTRPCData *> *)deletedIds {
    //In future, addedShowIndices could become NSIndexSet
    NSAssert(addedShowIndices.count == addedShows.count, @"Added RPC show problem");
    if (isConnecting) {
        //change during a Tivo XML refresh; need to restart after termination
        DDLogMajor(@"Show list change during Tivo %@ XML refresh", self);
        cancelRefresh = YES;
        return;
    }
    DDLogDetail(@"Updating Tivo %@ from RPC", self);
    DDLogVerbose(@"Adding %@ and deleting %@", addedShows, deletedIds);
    if (addedShows.count + deletedIds.count >= 10 ) {
        [self updateShows:self];  //too many changes, just reload the whole thing
        return;
    }
    NSMutableArray * showsAfterDeletions = [NSMutableArray arrayWithCapacity:self.shows.count];
    [self.shows enumerateObjectsUsingBlock:^(MTTiVoShow * _Nonnull show, NSUInteger showsIndex, BOOL * _Nonnull stop) {
        if (deletedIds[show.idString ] ){
            [self markDeletedDownloadShow:show];
        } else if (show.inProgress.boolValue) {
            //this is tricky.
            //pretend inProgress have been deleted and then added back in
            //so insert them into addedShows.
            //matching addedShowIndex is where it should end up.
            //everyone before this show is either in showsAfterDeletion OR in
            //addedShows with an index less than ours.
            NSUInteger addedIndex = [addedShowIndices indexOfObjectPassingTest:^BOOL(NSNumber * _Nonnull obj, NSUInteger indicesIdx, BOOL * _Nonnull stop2) {
                return obj.unsignedIntegerValue > showsAfterDeletions.count+indicesIdx;
            }];
           if (addedIndex == NSNotFound) addedIndex = addedShows.count;
            DDLogDetail(@"adding In Progress show %@(%@) to RPC added list at %d", show, show.idString, (int)addedIndex);
            [addedShows insertObject:show.idString atIndex:addedIndex];
            [addedShowIndices insertObject:@(showsAfterDeletions.count + addedIndex) atIndex:addedIndex];
        } else {
            [showsAfterDeletions addObject:show];
        }
    }];
    if (showsAfterDeletions) self.shows = showsAfterDeletions;
    DDLogVerbose(@"Previous shows after deletions were: %@:",showsAfterDeletions); 

    if (addedShows.count > 0) {
        self.addedShows =addedShows;
        self.addedShowIndices = addedShowIndices;
        [self startNPLDownload:NO];
    } else {
        [NSNotificationCenter  postNotificationNameOnMainThread:kMTNotificationTiVoShowsUpdated object:nil];
    }
}

-(NSRange) getFirstRange:(NSMutableArray <NSNumber *> *)indices {
    if (indices.count == 0) return NSMakeRange(0, 0);;
    NSUInteger end = 0;
    //look for sequence
    while (end+1 < indices.count && indices[end].unsignedIntegerValue +1 == indices[end+1].unsignedIntegerValue) end++;
    NSUInteger startValue = indices[0].unsignedIntegerValue;
    NSUInteger endValue = indices[end].unsignedIntegerValue;
    NSRange result = NSMakeRange(startValue,
                       endValue-startValue+1);
    DDLogDetail(@"First range is %@ for %@", NSStringFromRange(result), indices);
    return result;
}

-(void) startNPLDownload:(BOOL) getAll {
    
    if (isConnecting || !self.enabled) {
        DDLogDetail(@"But was %@", isConnecting? @"Connecting!": @"Disabled!");
        return;
    }
    if (self.showURLConnection) {
        [self.showURLConnection cancel];
        self.showURLConnection = nil;
    }
    isConnecting = YES;
    cancelRefresh = NO;
    [newShows removeAllObjects];

    [NSNotificationCenter  postNotificationNameOnMainThread:kMTNotificationTiVoUpdating object:self];
    if (self.currentNPLStarted) {
        [self saveLastLoadTime:self.currentNPLStarted];
    }
    self.currentNPLStarted = [NSDate date];
    self.oneBatch = !getAll;
    if (getAll) {
        [self updateShowsForRange:NSMakeRange(0, kMTNumberShowToGetFirst)];
    } else {
        [self updateShowsForRange:[self getFirstRange: self.addedShowIndices]];
    }
}

-(void) reloadShowInfoForID: (NSString *) showID {
    [self.myRPC reloadShowInfoForID:showID];
}

-(MTRPCData *) rpcDataForID: (NSString *) idString {
    return [self.myRPC rpcDataForID:idString];
}

-(BOOL) supportsTransportStream {
    NSString * TSN = self.tiVoSerialNumber;
    return TSN.length == 0 || [TSN characterAtIndex:0] > '6' || [TSN hasPrefix:@"663"] || [TSN hasPrefix:@"658"] || [TSN hasPrefix:@"652"];
}

-(BOOL) supportsRPC {
    return self.tiVoSerialNumber.length == 0 || [self.tiVoSerialNumber characterAtIndex:0] > '6' ;

}

-(BOOL) rpcActive {
    return self.myRPC != nil && self.myRPC.isActive;
}

-(NSArray < NSString *> *) recordingIDsForShows: (NSArray <MTTiVoShow *> *) shows {
    NSArray * recordingIds = [shows mapObjectsUsingBlock:^id(MTTiVoShow * show, NSUInteger idx) {
        if (show.tiVo != self) {
            return nil;
        } else {
            return show.rpcData.recordingID;
        }
    }];
    return recordingIds;
}

-(void) deleteTiVoShows: (NSArray <MTTiVoShow *> *) shows {
    [self.myRPC deleteShowsWithRecordIds:[self recordingIDsForShows:shows]];
}

-(void) stopRecordingTiVoShows: (NSArray <MTTiVoShow *> *) shows {
    [self.myRPC stopRecordingShowsWithRecordIds:[self recordingIDsForShows:shows]];

}
- (NSTimeInterval) roundTime: (NSTimeInterval) time {
    //rounds a timeinterval to wait up or down to nearest half hour (plus a minute) if not more than 10 minutes change
    //goal is to refresh Tivos shortly after they start/finish a recording rather than waiting too long
    NSDate * inDate =  [NSDate dateWithTimeIntervalSinceNow:time];

    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSInteger minutes = [calendar components: NSMinuteCalendarUnit fromDate: inDate].minute ;
    //round to updating at a minute after the half hour if reasonable
   if (minutes > 30) minutes -=30;
    NSInteger deltaTime = 0;
    if (minutes == 0) {
        deltaTime = 1;
    } if (minutes >= 2 && minutes <= 10) {
        deltaTime = 1-minutes;
    } else if (minutes >= 20) {
        deltaTime = 31-minutes;
    }

    return time + deltaTime*60;
}

-(void) scheduleNextUpdateAfterDelay:(NSInteger)delay {
    [MTTiVo cancelPreviousPerformRequestsWithTarget:self
                                           selector:@selector(updateShows:)
                                             object:nil ];
    if (delay < 0) {
        NSInteger minDelay =  [[NSUserDefaults standardUserDefaults] integerForKey:kMTUpdateIntervalMinutesNew];
        if (minDelay == 0) {
            minDelay = (self.rpcActive ?  kMTUpdateIntervalMinDefault : kMTUpdateIntervalMinDefaultNonRPC);
        }
        delay = [self roundTime:minDelay*60];
    }
    DDLogDetail(@"Scheduling Update with delay of %lu seconds", (long)delay);
    [self performSelector:@selector(updateShows:) withObject:nil afterDelay:delay ];
}

-(void)updateShows:(id)sender
{
	DDLogDetail(@"Updating Tivo %@", self);
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateShows:) object:nil];
    if (!self.enabled) return;
    previousShowList = [NSMutableDictionary dictionary];
	for (MTTiVoShow * show in _shows) {
		if(!show.inProgress.boolValue){
			[previousShowList setValue:show forKey:show.idString];
		}
	}
    DDLogVerbose(@"Previous shows were: %@:",previousShowList);
    [self startNPLDownload:YES];
}

-(NSInteger)isProcessing
{
    for (MTDownload *download in self.downloadQueue) {
        if (download.isInProgress && (download.downloadStatus.intValue != kMTStatusWaiting)) {
			return YES;
        }
    }
    return NO;
}

-(void)rescheduleAllShows
{
    for (MTDownload *download in self.downloadQueue) {
        if (download.isInProgress ) {
            [download prepareForDownload:NO];
        }
    }
}

-(void) updateShowsForRange:(NSRange) range {
    NSString *portString = @"";
    if ([_tiVo isKindOfClass:[MTNetService class]]) {
        portString = [NSString stringWithFormat:@":%d",_tiVo.userPortSSL];
    }

    NSString *tivoURLString = [[NSString stringWithFormat:@"https://%@%@/TiVoConnect?Command=QueryContainer&Container=%%2FNowPlaying&Recurse=Yes&AnchorOffset=%d&ItemCount=%d",_tiVo.hostName,portString,(int)range.location,(int)range.length] stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    if (self.oneBatch) {
        DDLogMajor(@"Loading RPC info from TiVo %@ shows from %d to %d at URL %@",self, (int)range.location, (int)NSMaxRange(range)-1, tivoURLString);
    } else if (previousShowList.count ==0 && range.location ==0) {
        //first time for this tivo:
        DDLogReport(@"Initial loading from TiVo %@ at URL %@",self, tivoURLString);
    } else {
        DDLogMajor(@"Loading from TiVo %@ shows from %d to %d at URL %@",self, (int)range.location, (int)NSMaxRange(range)-1, tivoURLString);
    }
    NSURL *tivoURL = [NSURL URLWithString:tivoURLString];
    NSURLRequest *tivoURLRequest = [NSURLRequest requestWithURL:tivoURL];
    self.showURLConnection = [NSURLConnection connectionWithRequest:tivoURLRequest delegate:self];
    [urlData setData:[NSData data]];
    authenticationTries = 0;
    [self.showURLConnection start];
}

-(void)resetAllDetails
{
    [self.myRPC emptyCaches];
    self.shows = nil;
}

#pragma mark - NSXMLParser Delegate Methods

-(void)parserDidStartDocument:(NSXMLParser *)parser
{
    parsingShow = NO;
    gettingContent = NO;
    gettingDetails = NO;
    numAddedThisBatch = 0;
}

-(void) startElement:(NSString *) elementName {
	//just gives a shorter method name for DDLog
	 DDLogVerbose(@"%@ Start: %@",self, elementName);
}

-(void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName attributes:(NSDictionary *)attributeDict
{
    if (LOG_VERBOSE) [self startElement:elementName];
	element = [NSMutableString string];
    if ([elementName compare:@"Item"] == NSOrderedSame) {
        parsingShow = YES;
        currentShow = [[MTTiVoShow alloc] init];
        currentShow.tiVo = self;
        gettingContent = NO;
        gettingDetails = NO;
        gettingIcon = NO;
    } else if ([elementName compare:@"Content"] == NSOrderedSame) {
        gettingContent = YES;
    } else if ([elementName compare:@"TiVoVideoDetails"] == NSOrderedSame) {
        gettingDetails = YES;
    } else if ([elementName compare:@"CustomIcon"] == NSOrderedSame) {
		gettingIcon = YES;
	}
}

-(void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string
{
    [element appendString:string];
}

-(void)parserElement:(NSString*) elementName {
	//just gives a shorter method name for DDLog
	DDLogVerbose(@"%@:  %@ --> %@",_tiVo.name,elementName,element);
}

-(void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName
{
	[self endElement:elementName];
}

-(void) endElement:(NSString *) elementName {
	//just gives a shorter method name for DDLog

	[self parserElement: elementName];
    if (parsingShow) {
        //extract show parameters here
//        [currentShow setValue:element forKey:elementToPropertyMap[elementName]];
		if ([elementName compare:@"TiVoVideoDetails"] == NSOrderedSame) {
			gettingDetails = NO;
		} else if ([elementName compare:@"Content"] == NSOrderedSame) {
			gettingContent = NO;
		} else if ([elementName compare:@"CustomIcon"] == NSOrderedSame) {
			gettingIcon = NO;
		} else if (gettingDetails) {
            //Get URL for details here
			if ([elementName caseInsensitiveCompare:@"Url"] == NSOrderedSame) {
				//If a manual tivo put in port information
				if (self.manualTiVo) {
					[self updatePortsInURLString:element];
				}
				[currentShow setValue:[NSURL URLWithString:element] forKey:@"detailURL"];
				DDLogVerbose(@"Detail URL is %@",currentShow.detailURL);
			}
        } else if (gettingContent) {
            //Get URL for Content here
			if ([elementName caseInsensitiveCompare:@"Url"] == NSOrderedSame) {
				NSRegularExpression *idRx = [NSRegularExpression regularExpressionWithPattern:@"id=(\\d+)" options:NSRegularExpressionCaseInsensitive error:nil];
				NSTextCheckingResult *idResult = [idRx firstMatchInString:element options:NSMatchingWithoutAnchoringBounds range:NSMakeRange(0, element.length)];
				if(idResult.range.location != NSNotFound){
					currentShow.showID = [[element substringWithRange:[idResult rangeAtIndex:1]] intValue];
				}
				if (self.manualTiVo) {
					[self updatePortsInURLString:element];
				}
				[currentShow setValue:[NSURL URLWithString:element] forKey:@"downloadURL"];
				DDLogVerbose(@"Content URL is %@",currentShow.downloadURL);
			}
        } else if (gettingIcon) {
            //Get name of Icon here
			if ([elementName caseInsensitiveCompare:@"Url"] == NSOrderedSame) {
				NSString *introURL = @"urn:tivo:image:";
				if ([element hasPrefix: introURL]){
					currentShow.imageString = [element substringFromIndex:introURL.length];
				} 
				DDLogVerbose(@"Image String is %@",currentShow.imageString);
			}
        } else if ([elementToPropertyMap objectForKey:elementName]){
//        [currentShow setValue:element forKey:elementToPropertyMap[elementName]];
			int type = [elementToPropertyMap[elementName][kMTType] intValue];
			id valueToSet = nil;
			NSString * keyToSet = elementToPropertyMap[elementName][kMTValue];
			switch (type) {
                case kMTStringType:
                    //Process String Type here
					valueToSet = element;
                    break;
                    
                case kMTBoolType:
                    //Process Boolean Type here
					valueToSet = [NSNumber numberWithBool:[element boolValue]];
                    break;
                                        
                case kMTNumberType:
                    //Process Number Type here
 					valueToSet = [NSNumber numberWithDouble:[element doubleValue]];
                   break;
                    
			   case kMTDateType: {
                    //Process date type which are hex timestamps
				   double timestamp = 0;
					[[NSScanner scannerWithString:element] scanHexDouble:&timestamp];
//					timestamp = [element doubleValue];
					valueToSet = [NSDate dateWithTimeIntervalSince1970:timestamp];
                   break;
			   }
                default:
                    break;
            }
			if (valueToSet) [currentShow setValue:valueToSet forKey:keyToSet];
			DDLogVerbose(@"set %@ (type %d) to %@ for %@",keyToSet, type, valueToSet, elementName);

        } else if ([elementName compare:@"Item"] == NSOrderedSame) {
            parsingShow = NO;
            DDLogVerbose(@"Done loading XML for %@",currentShow);
            for (MTTiVoShow * oldShow in newShows) {
                if ([oldShow isEqualTo:currentShow]) {
                    DDLogDetail(@"Skipping duplicate new %@show %@ (%@) ",currentShow.isSuggestion ? @"suggested ":@"", currentShow.showTitle, currentShow.showDateString);
                    currentShow = nil;
                    return;
                }
            }
            if (currentShow.inProgress.boolValue) {
                //can't use actual npl time, must use just before earliest in-progress so when it finishes, we'll pick it up next time
                NSDate * backUpToTime = [ currentShow.showDate dateByAddingTimeInterval:-1];
                if ([backUpToTime isLessThan:self.currentNPLStarted]) {
                    self.currentNPLStarted = backUpToTime;
                }
            }
            NSString * newShowID = currentShow.idString;
            MTTiVoShow *thisShow = nil;
           if (self.oneBatch) {
               for (NSString * showID in self.addedShows) {
                    if ([newShowID isEqualToString:showID]) {
                        thisShow = currentShow;
                        DDLogMajor(@"RPC Adding %@ at %@", currentShow, newShowID);
                        [self.addedShows removeObject:showID];
                       break;
                    }
               }
               if (!thisShow) {
                    DDLogMajor(@"RPC out of sync: %@ v %@ Indices: %@", newShowID, self.addedShows, self.addedShowIndices );
                    cancelRefresh = YES;
                }
            } else {
                thisShow = [previousShowList valueForKey:newShowID];
                if (thisShow) {
                    DDLogDetail(@"Updated show %@", currentShow.showTitle);
                    [previousShowList removeObjectForKey:newShowID];
                    if (thisShow.inProgress.boolValue) thisShow = currentShow;
                } else {
                    thisShow = currentShow;
                    DDLogDetail(@"Added new %@show %@ (%@) ",currentShow.isSuggestion ? @"suggested " : @"", currentShow.showTitle, currentShow.showDateString);
                    //Now check and see if this was in the oldQueue (from last ctivo execution)
                    if (firstUpdate) [tiVoManager replaceProxyInQueue:currentShow];
                }
           }
            if (thisShow) {
                [newShows addObject:thisShow];
                numAddedThisBatch++;
                if (!thisShow.gotDetails) {
                   NSInvocationOperation *nextDetail = [[NSInvocationOperation alloc] initWithTarget:thisShow selector:@selector(getShowDetail) object:nil];
                    [self.opsQueue addOperation:nextDetail];

                }
           }
			currentShow = nil;
        }
    } else {
        if ([elementName compare:@"TotalItems"] == NSOrderedSame) {
            totalItemsOnTivo = [element intValue];
			DDLogDetail(@"TotalItems: %d",totalItemsOnTivo);
        } else if ([elementName compare:@"ItemStart"] == NSOrderedSame) {
            itemStart = [element intValue];
			DDLogVerbose(@"ItemStart: %d",itemStart);
        } else if ([elementName compare:@"ItemCount"] == NSOrderedSame) {
            itemCount = [element intValue];
			DDLogVerbose(@"ItemCount: %d",itemCount);
        } else if ([elementName compare:@"LastChangeDate"] == NSOrderedSame) {
            int newLastChangeDate = [element intValue];
            if (newLastChangeDate != lastChangeDate) {
				DDLogVerbose(@"Oops. Date changed under us: was: %d now: %d",lastChangeDate, newLastChangeDate);
                //Implement start over here
				//except that a show in progress updates this value
            }
            lastChangeDate = newLastChangeDate;
        } else {
			DDLogVerbose(@"Unrecognized element: %@-->%@",elementName,element);
			
		}
    }
}


-(void)updatePortsInURLString:(NSMutableString *)elementToUpdate
{
	NSRegularExpression *portRx = [NSRegularExpression regularExpressionWithPattern:@"\\:(\\d+)\\/" options:NSRegularExpressionCaseInsensitive error:nil];
	NSTextCheckingResult *portMatch = [portRx firstMatchInString:elementToUpdate options:0 range:NSMakeRange(0, elementToUpdate.length)];
	if (portMatch.numberOfRanges == 2) {
        NSRange portRange = [portMatch rangeAtIndex:1];
		NSString *portString = [elementToUpdate substringWithRange:portRange];
        short port = -1;

		if ([portString compare:@"443"] == NSOrderedSame) {
            port = self.tiVo.userPortSSL;
        } else if ([portString compare:@"80"] == NSOrderedSame) {
            port = self.tiVo.userPort;
		}
        if ( port > 0 ) {
            NSString * portReplaceString = [NSString stringWithFormat:@"%d", port];
            DDLogVerbose(@"Replacing port %@ with %@",portString, portReplaceString);
            [elementToUpdate replaceCharactersInRange:portRange withString:portReplaceString] ;
        }
	}
}

-(void) markDeletedDownloadShow: (MTTiVoShow *) deletedShow {
    if (deletedShow.isQueued) {
        MTDownload * download = [tiVoManager findInDownloadQueue:deletedShow];
        if (download.isNew) {
            download.downloadStatus = @(kMTStatusDeleted);
        }
        deletedShow.imageString = @"deleted";
    }
}

-(void)parserDidEndDocument:(NSXMLParser *)parser
{
	//Check if we're done yet
    int numDuplicates =itemCount-numAddedThisBatch;
    if (itemCount == 0) {
        if (self.oneBatch) {
            DDLogReport(@"TiVo returned ZERO of %d requested shows for RPC!", (int)[self getFirstRange:self.addedShowIndices].length);
        } else {
            DDLogReport(@"TiVo returned ZERO requested shows! Ignoring shows from %d to %d", itemStart, totalItemsOnTivo);
        }
    } else if (numDuplicates == 0) {
        DDLogMajor(@"Finished batch for %@. Added %d shows.", self, numAddedThisBatch);
    } else if (numAddedThisBatch == 0) {  //Streaming Movies reported as shows bug
        DDLogMajor(@"Finished batch for %@. Only duplicated shows.", self);
    } else {
        DDLogMajor(@"Finished batch for %@. Added %d shows, but %d duplicate%@.", self, numAddedThisBatch, numDuplicates, numDuplicates == 1 ? @"": @"s" );
    }

    if (cancelRefresh) {
        //had some kind of sync problem, so start all over.
        DDLogReport(@"Resynching TiVo %@!", self);
        isConnecting = NO;
        [NSNotificationCenter postNotificationNameOnMainThread:kMTNotificationTiVoUpdated object:self];
       [self scheduleNextUpdateAfterDelay:0];
    } else if (self.oneBatch) {
        NSRange currentBatch = [self getFirstRange:self.addedShowIndices];
        if (currentBatch.length != newShows.count ||
            currentBatch.location > self.shows.count) {
            DDLogMajor(@"TiVo %@ out of RPC sync!", self);
            isConnecting = NO;
            [NSNotificationCenter postNotificationNameOnMainThread:kMTNotificationTiVoUpdated object:self];
            [self scheduleNextUpdateAfterDelay:0];
        } else {
            DDLogDetail(@"got next batch %@ of RPC: %@", NSStringFromRange(currentBatch), newShows);
            NSMutableArray * updatedShows = [self.shows mutableCopy];
            [updatedShows insertObjects:newShows atIndexes:[NSIndexSet indexSetWithIndexesInRange:currentBatch]];
            self.shows = updatedShows;
            [newShows removeAllObjects];
            [self.addedShowIndices removeObjectsInRange:NSMakeRange(0, currentBatch.length)];
            if (self.addedShowIndices.count > 0) {
                [self updateShowsForRange :[self getFirstRange:self.addedShowIndices]];
            } else {
                isConnecting = NO;
                [NSNotificationCenter postNotificationNameOnMainThread:kMTNotificationTiVoUpdated object:self];
            }
        }
    } else if (self.enabled  && (itemCount > 0 && itemStart+itemCount < totalItemsOnTivo)) { // && numAddedThisBatch > 0) {
        DDLogDetail(@"More shows to load from %@", self);
        if (newShows.count > _shows.count) {
            self.shows = [NSArray arrayWithArray:newShows];
        }
        [self updateShowsForRange :NSMakeRange( itemStart + itemCount,kMTNumberShowToGet)];
    } else {
        isConnecting = NO;
        DDLogMajor(@"TiVo %@ completed full update", self);
        self.shows = [NSArray arrayWithArray:newShows];
        if (firstUpdate) {
            [tiVoManager checkDownloadQueueForDeletedEntries:self];
            firstUpdate = NO;
        }
        [self scheduleNextUpdateAfterDelay:-1];
        DDLogVerbose(@"Deleted shows: %@",previousShowList);
        for (MTTiVoShow * deletedShow in [previousShowList objectEnumerator]){
            [self markDeletedDownloadShow:deletedShow];
        };
        [NSNotificationCenter postNotificationNameOnMainThread:kMTNotificationTiVoUpdated object:self];

        previousShowList = nil;
        //allows reporting when all other ops completed
        NSInvocationOperation *nextDetail = [[NSInvocationOperation alloc] initWithTarget:self selector:@selector(detailsComplete) object:nil];
        [self.opsQueue addOperation:nextDetail];
	}
    [NSNotificationCenter postNotificationNameOnMainThread:kMTNotificationTiVoShowsUpdated object:nil];
	[NSNotificationCenter postNotificationNameOnMainThread:kMTNotificationDownloadQueueUpdated object:self];

}

- (void)parser:(NSXMLParser *)parser parseErrorOccurred:(NSError *)parseError {
    DDLogReport(@"TiVo %@ had parsing error: %@", self, parseError.localizedDescription);
    isConnecting = NO;
    [NSNotificationCenter postNotificationNameOnMainThread:kMTNotificationTiVoUpdated object:self];

    [self scheduleNextUpdateAfterDelay:-1];
    previousShowList = nil;

}


-(void) detailsComplete {
    //called when each show completes its details
    //DDLogReport (@"Ops Count = %lu; shows = %lu; connection: %@; queue = %@", (unsigned long)self.opsQueue.operationCount, self.shows.count, self.showURLConnection, self.opsQueue);

    if (self.opsQueue.operationCount <= 1 && !tiVoManager.tvdb.isActive && !isConnecting) {
        DDLogMajor(@"Got all details for %@",self.tiVo.name);
        DDLogDetail(@"Statistics for TVDB since start or reset: %@",[tiVoManager.tvdb stats]);

        //        for testing the movidedB
        //        for (MTTiVoShow * show in [self.shows copy]) {
        //            if (show.isMovie) {
        //                [show retrieveTheMovieDBArtworkIntoPath: [tiVoManager.tmpFilesDirectory stringByAppendingPathComponent:show.seriesTitle]];
        //                usleep(50000);
        //            }
        //        }
    }
}


#pragma mark - Download Management

-(NSArray *)downloadQueue
{
    return [tiVoManager downloadQueueForTiVo:self];
}

-(void)manageDownloads:(id)info
{
//    if ([tiVoManager.hasScheduledQueueStart boolValue]  && [tiVoManager.queueStartTime compare:[NSDate date]] == NSOrderedDescending) { //Don't start unless we're after the scheduled time if we're supposed to be scheduled.
//        DDLogMajor(@"%@ Delaying download until %@",self,tiVoManager.queueStartTime);
//		return;
//    }
	if ([tiVoManager checkForExit]) return;
	if (tiVoManager.processingPaused.boolValue) return;

	if ([info isKindOfClass:[NSNotification class]]) {
		NSNotification *notification = (NSNotification *)info;
		if (!notification.object || notification.object == self) {
			DDLogDetail(@"%@ got manageDownload notification %@",self, notification.name);
			[self manageDownloads];
		} else {
			DDLogDetail(@"%@ ignoring notification %@ for %@",self,notification.name, notification.object);
		}
	} else if ([info isKindOfClass:[self class]] && info == self ) {
			[self manageDownloads];
	} else {
		DDLogMajor(@"Unrecognized info to launch manageDownloads %@",info);
	}

}

-(void)manageDownloads
{
	DDLogMajor(@"Checking %@ queue", self);
	if (managingDownloads) {
        return;
    }
    managingDownloads = YES;
    //We are only going to have one each of Downloading, Encoding, and Decrypting.  So scan to see what currently happening
//	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(manageDownloads) object:nil];
    BOOL isDownloading = NO;
    for (MTDownload *s in self.downloadQueue) {
        if (s.isDownloading) {
            isDownloading = YES;
            break;
        }
    }
    if (!isDownloading) {
		DDLogDetail(@"%@ Checking for new download", self);
		for (MTDownload *s in self.downloadQueue) {
			if ([s.show.protectedShow boolValue]) {
				managingDownloads = NO;
				return;
			}
            if (s.isNew && (tiVoManager.numEncoders < [[NSUserDefaults standardUserDefaults] integerForKey: kMTMaxNumEncoders])) {
                if(s.show.tiVo.isReachable) {  //isn't this self.isReachable?
					tiVoManager.numEncoders++;
					DDLogMajor(@"Num encoders after increment in MTTiVo %@ for show \"%@\"  is %d",self.tiVo.name,s.show.showTitle, tiVoManager.numEncoders);
					[s launchDownload];
                }
                break;
            }
        }
    }
    managingDownloads = NO;
}

#pragma mark - Helper Methods

-(long) parseTime: (NSString *) timeString {
	NSRegularExpression *timeRx = [NSRegularExpression regularExpressionWithPattern:@"([0-9]{1,3}):([0-9]{1,2}):([0-9]{1,2})" options:NSRegularExpressionCaseInsensitive error:nil];
	NSTextCheckingResult *timeResult = [timeRx firstMatchInString:timeString options:NSMatchingWithoutAnchoringBounds range:NSMakeRange(0, timeString.length)];
	if (timeResult) {
		NSInteger hr = [timeString substringWithRange:[timeResult rangeAtIndex:1]].integerValue ;
		NSInteger min = [timeString substringWithRange:[timeResult rangeAtIndex:2]].integerValue ;
		NSInteger sec = [timeString substringWithRange:[timeResult rangeAtIndex:3]].integerValue ;
		return hr*3600+min*60+sec;
	} else {
		return 0;
	}
}


#pragma mark - NSURL Delegate Methods

-(void)notifyUserWithTitle:(NSString *) title subTitle: (NSString*) subTitle { // notification of Tivo problem
    [tiVoManager notifyForName: self.tiVo.name
              withTitle: title
               subTitle: subTitle
               isSticky: YES
     ];
}

-(void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
	DDLogVerbose(@"TiVo %@ sent data",self);
    if(self.manualTiVo) _isReachable = YES;
	[urlData appendData:data];
}

- (void)connection:(NSURLConnection *)connection willSendRequestForAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
{
	if (challenge.previousFailureCount == 0) {
		DDLogDetail(@"%@ password ask",self);
        if (challenge.proposedCredential) {
            DDLogDetail(@"Got mediaKey from keyChain");
            NSString * newPassword = challenge.proposedCredential.password;
            if (newPassword && ![newPassword isEqualToString:self.mediaKey]) {
                self.mediaKey = newPassword;
                [tiVoManager performSelectorOnMainThread:@selector(updateTiVoDefaults:) withObject:self waitUntilDone:NO];
            }

            [challenge.sender useCredential:challenge.proposedCredential forAuthenticationChallenge:challenge];
        } else {
            DDLogDetail(@"sending mediaKey from userDefaults");
           NSURLCredentialPersistence persistance = NSURLCredentialPersistenceForSession;
            if (self.storeMediaKeyInKeychain) {
                persistance = NSURLCredentialPersistencePermanent;
            }
            NSURLCredential *myCredential = [NSURLCredential credentialWithUser:@"tivo" password:self.mediaKey persistence:persistance];
            [challenge.sender useCredential:myCredential forAuthenticationChallenge:challenge];
        }
	} else {
		DDLogReport(@"%@ challenge failed",self);
		[challenge.sender cancelAuthenticationChallenge:challenge];
		[self.showURLConnection cancel];
		self.showURLConnection = nil;
		isConnecting = NO;
        [NSNotificationCenter postNotificationNameOnMainThread:kMTNotificationTiVoUpdated object:self];
		[NSNotificationCenter postNotificationNameOnMainThread:kMTNotificationMediaKeyNeeded object:@{@"tivo" : self, @"reason" : @"incorrect"}];
	}
}


-(void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
    DDLogReport(@"TiVo URL Connection Failed with error %@",[error maskMediaKeys]);
    NSNumber * streamError = error.userInfo[@"_kCFStreamErrorCodeKey"];
    DDLogDetail(@"URL ErrorCode: %@, streamErrorCode: %@ (%@)", @(error.code), streamError, [streamError class]);
    if (error.code == -1004 && [streamError isKindOfClass:[NSNumber class]] && streamError.intValue == 49) {
        [self notifyUserWithTitle: @"Warning: Could not reach TiVo!"
                          subTitle:@"Antivirus program may be blocking connection"];
    }

    [NSNotificationCenter postNotificationNameOnMainThread: kMTNotificationTiVoUpdated object:self];
//    [self reportNetworkFailure];
    if(self.manualTiVo) _isReachable = NO;
    self.showURLConnection = nil;
    
    isConnecting = NO;
	
}


-(void)connectionDidFinishLoading:(NSURLConnection *)connection
{
	DDLogDetail(@"%@ URL Connection completed ",self);
    DDLogVerbose(@"Data received is %@",[[NSString alloc] initWithData:urlData encoding:NSUTF8StringEncoding]);

    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:urlData];
	parser.delegate = self;
	[parser parse];
    self.showURLConnection = nil;
}

#pragma mark - Memory Management

-(void)dealloc
{
    DDLogDetail(@"Deallocing TiVo %@",self);
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	SCNetworkReachabilityUnscheduleFromRunLoop(_reachability, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
	if (_reachability) {
		CFRelease(_reachability);
	}
    _reachability = nil;
    [self.myRPC stopServer];
    self.tiVo = nil;
    self.myRPC = nil;
}

@end
