//
//  MTTask.h
//  cTiVo
//
//  Created by Scott Buchanan on 4/9/13.
//  Copyright (c) 2013 cTiVo. All rights reserved.
//

#import <Foundation/Foundation.h>

@class MTDownload, MTTaskChain;

@interface MTTask : NSObject

@property (strong, nonatomic) NSTask *task;

@property (strong, nonatomic) NSString	*taskName,
//                                        *baseName,
//										*outputFilePath,
										*logFilePath,
										*errorFilePath;

@property (strong, nonatomic) NSFileHandle	*outputFileHandle,
											*errorFileHandle,
											*logFileWriteHandle,
											*logFileReadHandle;

@property (strong, nonatomic) NSRegularExpression *trackingRegEx; //not currently used

@property (weak, nonatomic) MTTaskChain *myTaskChain;

@property (weak, nonatomic) MTDownload *download;

//Startup is called just before launch, and can abort by returning false
//Completion is called on successful completion, and can convert to failure by returning false
//Termination handler is called upon cancellation only
//Cleanup is called on any termination, including dealloc
@property (nonatomic, copy) void (^terminationHandler)(void);

@property (nonatomic, copy) BOOL (^startupHandler)(void), (^completionHandler)(void);

@property (nonatomic, copy) double (^progressCalc)(NSString *data);

@property (nonatomic, copy) void (^cleanupHandler)(void);

@property BOOL requiresInputPipe, requiresOutputPipe, shouldReschedule;
@property (nonatomic, readonly) BOOL taskFailed;
@property (atomic) BOOL taskRunning;
@property (nonatomic, readonly) BOOL successfulExit;

@property int pid;

@property (nonatomic, strong) NSArray *successfulExitCodes;

+(MTTask *)taskWithName:(NSString *)name download:(MTDownload *)download;
+(MTTask *)taskWithName:(NSString *)name download:(MTDownload *)download completionHandler:(BOOL(^)(void))completionHandler;

-(void)setLaunchPath:(NSString *)path;
-(void)setCurrentDirectoryPath:(NSString *)path;
-(void)setEnvironment:(NSDictionary *)env;
-(void)setArguments:(NSArray *)args;
-(void)setStandardOutput:(id)stdo;
-(void)setStandardInput:(id)stdi;
-(void)setStandardError:(id)stde;
-(void)launch;
-(void)terminate;
-(void)interrupt;
-(void)suspend;
-(void)waitUntilExit;
-(BOOL)isRunning;
-(void)cleanUp;
-(void)cancel;
-(void) saveLogFile;


@end
