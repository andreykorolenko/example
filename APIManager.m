//
//  APIManager.m
//  -
//
//  Created by Андрей Короленко on 20.05.16.
//  Copyright © 2016 Андрей Короленко. All rights reserved.
//

#import "APIManager.h"
#import "Session.h"
#import "SSKeychain.h"

#import "Fine.h"
#import "Car.h"
#import "Driver.h"

#import "Config.h"
#import "Error.h"
#import "FineManager.h"
#import "Notification.h"
#import <MagicalRecord/MagicalRecord.h>
#import <Reachability/Reachability.h>

// authorization
static NSString *authHost = @"";
static NSString *authClientID = @"";
static NSString *authClientSecret = @"";

// saving data
static NSString *userTokenService = @"";
static NSString *userPhoneNumberService = @"";

// payments of a fine
static NSString *paymentHost = @"";
static NSString *finesHost = @"";

static NSString *errorDomain = @"";

@interface APIManager ()

@property(nonatomic, copy) NSString *authorizationCode;

@property (nonatomic, strong) NSURLSessionDataTask *dataTask;

@end

@implementation APIManager


+ (id)sharedManager {
    static APIManager *sharedManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedManager = [[self alloc] init];
    });
    return sharedManager;
}

- (void)checkReachability {
    
    Reachability *reach = [Reachability reachabilityWithHostname:@"www.google.com"];
    
    reach.unreachableBlock = ^(Reachability *reach) {
        [Error showError:@"Отсутствует подключение к интернету" completion:nil];
    };
    
    [reach startNotifier];
}


#pragma mark - Authorization

- (BOOL)isAuthorized {
    
    return self.token != nil;
}

- (void)logout {
    
    [[FineManager sharedManager] removeAllObjects];
    [self removeToken];
}

- (NSDictionary *)defaultAuthHeaders {

    return @{
            @"charset" : @"utf-8",
            @"Accept" : @"text/json",
            @"Authorization" : [Session authorizationHeaderWithName:authClientID password:authClientSecret]
    };
}

- (void)authorizationWithPhone:(NSString *)phone
           withCompletionBlock:(StandartRequestCompletionBlock)completionBlock {
    
    [self checkReachability];
    
    NSString *url = [NSString stringWithFormat:@"%@/oauth/authorize", authHost];
    
    NSDictionary *params = @{@"response_type" : @"code",
                             @"username" : phone};
    
    NSMutableURLRequest *request = [Session PostFormUrlEncodedRequestWithUrl:url parameters:params headers:[self defaultAuthHeaders]];
    
    [Session startTaskWithRequest:request JSONCompletionHandler:^(id jsonDictionary, NSInteger statusCode, NSError *error) {
        
        NSString *code = [Session safeStringForKey:@"code" fromDictionary:jsonDictionary];
        
        if (code) {
            
            self.phoneNumber = phone;
            self.authorizationCode = code;
            if (completionBlock)
                completionBlock(YES, nil);
            
        } else if (completionBlock) {
            
            NSString *errorMessage = [Session safeStringForKey:@"user_message" fromDictionary:jsonDictionary];
            if (!errorMessage && error) {
                if (![error.userInfo[NSLocalizedDescriptionKey] isEqualToString:@"The Internet connection appears to be offline."]) {
                    [Error showError:error.userInfo[NSLocalizedDescriptionKey] completion:nil];
                    completionBlock(NO, error.userInfo[NSLocalizedDescriptionKey]);
                    return;
                } else {
                    completionBlock(NO, nil);
                    return;
                }
            }
            [Error showError:errorMessage completion:nil];
        }
    }];
}

- (void)confirmAuthorizationWithSMSCode:(NSString *)smsCode
                    withCompletionBlock:(StandartRequestCompletionBlock)completionBlock {

    if (!self.authorizationCode) {
        if (completionBlock) {
            completionBlock(NO, @"Запросите новый код подтверждения");
        }
        return;
    }

    NSString *url = [NSString stringWithFormat:@"%@/oauth/token", authHost];

    NSDictionary *params = @{
            @"grant_type" : @"",
            @"code" : self.authorizationCode,
            @"vcode" : smsCode};

    NSMutableURLRequest *request = [Session PostFormUrlEncodedRequestWithUrl:url parameters:params headers:[self defaultAuthHeaders]];

    [Session startTaskWithRequest:request JSONCompletionHandler:^(id jsonDictionary, NSInteger statusCode, NSError *error) {

        NSString *accessToken = [Session safeStringForKey:@"access_token" fromDictionary:jsonDictionary];

        if (accessToken) {

            self.token = accessToken;

            if (completionBlock)
                completionBlock(YES, nil);

        } else {

            if (completionBlock) {
                NSString *errorMessage = [Session safeStringForKey:@"user_message" fromDictionary:jsonDictionary];
                if (!errorMessage && error) {
                    errorMessage = error.userInfo[NSLocalizedDescriptionKey];
                }
                completionBlock(NO, errorMessage);
            }
        }
    }];
}


#pragma mark - Load Fines

- (void)sendUpdateNotificationWithUserInfo:(NSDictionary *)userInfo {
    NSLog(@"API MANAGER: FINES UPDATED");
    [[NSNotificationCenter defaultCenter] postNotificationName:NOTIFICATION_DID_FINES_UPDATED object:nil userInfo:userInfo];
}

- (NSDictionary *)defaultFinesHeaders {

    return @{
            @"charset" : @"utf-8",
            @"Content-Type" : @"application/json",
            @"Accept-Language" : @"ru",
            @"Authorization" : [NSString stringWithFormat:@"Bearer %@", self.token]
    };
}

- (NSDictionary *)defaultFinesHeadersV1 {

    return @{
            @"charset" : @"utf-8",
            @"Content-Type" : @"application/json",
            @"Accept-Language" : @"ru",
            @"User-Agent" : @"IPHONE",
            @"X-Application-Id" : @"-",
            @"X-Application-Secret" : @"-",
            @"Accept" : @"-",
            @"Authorization" : [Session authorizationHeaderWithName:self.phoneNumber password:self.token prefix:@"Token"]
    };
}

- (NSDictionary *)defaultFinesHeadersV2 {
    
    return @{
             @"charset" : @"utf-8",
             @"Content-Type" : @"application/json",
             @"Accept-Language" : @"ru",
             @"User-Agent" : @"IPHONE",
             @"X-Application-Id" : @"-",
             @"X-Application-Secret" : @"-",
             @"Accept" : @"-",
             @"Authorization" : [Session authorizationHeaderWithName:self.phoneNumber password:self.token prefix:@"Token"]
             };
}

- (void)updateFinesFromServer {
    
    if (self.dataTask.state == NSURLSessionTaskStateRunning) {
        [self.dataTask cancel];
    };
    
    [self getListOfFinesWithCompletionBlock:^(id object, NSError *error) {
        [self sendUpdateNotificationWithUserInfo:@{}];
    }];
}

- (void)getListOfFinesWithCompletionBlock:(RequestCompletionBlock)completionBlock {
    
    [self checkReachability];

    NSString *url = [NSString stringWithFormat:@"%@/fines", finesHost];
    NSDictionary *headers = [self defaultFinesHeaders];
    NSMutableURLRequest *request = [Session GetRequestWithUrl:url headers:headers];

    [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;

    self.dataTask = [Session startTaskWithRequest:request JSONCompletionHandler:^(id jsonResponse, NSInteger statusCode, NSError *error) {

        [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;

        // check request error
        if (!jsonResponse || error) {
            completionBlock(nil, error);
            return;
        }
        NSDictionary *resultCode = [Session safeDictionary:jsonResponse[@"resultCode"]];
        NSInteger code = [resultCode[@"code"] integerValue];
//        NSString *message = [resultCode[@"message"] description];

        // check response error
        if (code != 0) {
            
            [Error showUnknownErrorСompletion:nil];
            NSError *errorInResponse;
            completionBlock(nil, errorInResponse);
            return;
        }

        // no errors
        NSArray *jsonFines = [Session safeObject:jsonResponse[@"fines"]];
        NSArray *fines = [self processFinesResponse:jsonFines];
        
          if (completionBlock) {
              completionBlock(fines, error);
          }
    }];
}

- (NSArray *)processFinesResponse:(NSArray *)jsonFines  {

    __block NSArray *fines = [NSArray array];
    
    NSArray *unpaidFines = [Fine fetchFinePaidFetchRequest:[NSManagedObjectContext MR_defaultContext] paid:@0];
    for (Fine *fine in unpaidFines) {
        [fine MR_deleteEntityInContext:[NSManagedObjectContext MR_defaultContext]];
    }
    [[NSManagedObjectContext MR_defaultContext] MR_saveToPersistentStoreAndWait];

    [jsonFines enumerateObjectsUsingBlock:^(id jsonFine, NSUInteger idx, BOOL *stop) {

        [MagicalRecord saveWithBlockAndWait:^(NSManagedObjectContext *_Nonnull localContext) {

            Fine *fine = [Fine fineWithOrdinanceNumber:[Session safeObject:jsonFine[@"ordinanceNumber"]]
                                               content:jsonFine
                                             inContext:localContext];
            
            // найти объект по documentNumber
            NSArray *cars = [Car fetchCarByCertificateFetchRequest:localContext regCertificate:fine.documentNumber];
            if (cars.count > 0) {
                [fine setCar:[[cars firstObject] MR_inContext:localContext]];
            } else {
                NSArray *drivers = [Driver fetchDriverLicenseFetchRequest:localContext numberLicense:fine.documentNumber];
                if (drivers.count > 0) {
                    [fine setDriver:[[drivers firstObject] MR_inContext:localContext]];
                }
            }

            fines = [fines arrayByAddingObject:fine];
        }];

        [[NSManagedObjectContext MR_defaultContext] MR_saveToPersistentStoreAndWait];
    }];

    return fines;
}


#pragma mark - Payment

- (void)payFine:(Fine *)fine withCompletion:(StandartRequestCompletionBlock)completion {
    
    // валидация
    // TODO: In progress
    NSMutableURLRequest *request = [Session PostJsonRequestWithUrl:@"-" parameters:[fine paymentInfo] headers:[self defaultFinesHeadersV2]];
    
    [Session startTaskWithRequest:request JSONCompletionHandler:^(id jsonDictionary, NSInteger statusCode, NSError *error) {
        
    }];
}


#pragma mark - Cards

// список карт
- (void)getListOfCardsWithCompletionBlock:(RequestCompletionBlock)completionBlock {
    
    NSString *url = [NSString stringWithFormat:@"%@/user/linkedCards", paymentHost];
    
    NSMutableURLRequest *request = [Session GetRequestWithUrl:url headers:[self defaultFinesHeadersV2]];
    
    [Session startTaskWithRequest:request JSONCompletionHandler:^(id jsonObject, NSInteger statusCode, NSError *error) {
        
        if (completionBlock) {
            completionBlock(jsonObject, error);
        }
    }];
}


#pragma mark - Cars

- (void)getCarsFromServerWithCompletionBlock:(RequestCompletionBlock)completionBlock {
    
    NSMutableURLRequest *request = [Session GetRequestWithUrl:[self vehicleURL] headers:[self defaultFinesHeaders]];
    
    [Session startTaskWithRequest:request JSONCompletionHandler:^(id jsonObject, NSInteger statusCode, NSError *error) {
        
        if (!error && jsonObject) {
            for (NSDictionary *result in (NSArray *)jsonObject) {
                [MagicalRecord saveWithBlockAndWait:^(NSManagedObjectContext * _Nonnull localContext) {
                    [self carFromDictionary:result inContext:localContext];
                }];
            }
            [[NSManagedObjectContext MR_defaultContext] MR_saveToPersistentStoreAndWait];
        }
        
        if (completionBlock) {
            completionBlock(nil, error);
        }
    }];
}

- (void)addCarWithModelName:(NSString *)modelName
             regCertificate:(NSString *)regCertificate
                  regNumber:(NSString *)regNumber
            сompletionBlock:(RequestCompletionBlock)completionBlock {
    
    __block Car *car;
    [MagicalRecord saveWithBlockAndWait:^(NSManagedObjectContext * _Nonnull localContext) {
        car = [Car carWithName:modelName regCertificate:regCertificate regNumber:regNumber inContext:localContext];
        if (completionBlock) {
            completionBlock (car, nil);
        }
    }];
    [[NSManagedObjectContext MR_defaultContext] MR_saveToPersistentStoreAndWait];
                
                
    NSDictionary *parameters = @{@"number": regCertificate,
                                 @"vehicleRegistrationNumber": regNumber,
                                 @"name": modelName};
                
    NSMutableURLRequest *request = [Session PostJsonRequestWithUrl:[self vehicleURL] parameters:(NSDictionary *)@[parameters] headers:[self defaultFinesHeaders]];
                
    [Session startTaskWithRequest:request JSONCompletionHandler:^(id jsonDictionary, NSInteger statusCode, NSError *error) {
        
        if (!error && jsonDictionary && statusCode != 400) {
            NSDictionary *dict = jsonDictionary[0];
            car = [car MR_inContext:[NSManagedObjectContext MR_defaultContext]];
            car.car_id =  [Session safeNumberForKey:@"id" fromDictionary:dict];
            [[NSManagedObjectContext MR_defaultContext] MR_saveToPersistentStoreAndWait];
            [self updateFinesFromServer];
        } else {
            [Error showUnknownErrorСompletion:nil];
        }
    }];
}

- (void)updateCar:(Car *)car withModelName:(NSString *)modelName
   regCertificate:(NSString *)regCertificate
        regNumber:(NSString *)regNumber
  сompletionBlock:(RequestCompletionBlock)completionBlock {
    
    [MagicalRecord saveWithBlockAndWait:^(NSManagedObjectContext * _Nonnull localContext) {
        [car updateWithModelName:modelName regCertificate:regCertificate regNumber:regNumber inContext:localContext];
        if (completionBlock) {
            completionBlock (car, nil);
        }
    }];
    [[NSManagedObjectContext MR_defaultContext] MR_saveToPersistentStoreAndWait];
    
      NSDictionary *parameters = @{@"id": car.car_id,
                                   @"number": regCertificate ? regCertificate : @"",
                                   @"vehicleRegistrationNumber": regNumber ? regNumber : @"",
                                   @"name": modelName ? modelName : @""};
      
      NSMutableURLRequest *request = [Session PutJsonRequestWithUrl:[self vehicleURL] parameters:(NSDictionary *)@[parameters] headers:[self defaultFinesHeaders]];
      
      [Session startTaskWithRequest:request JSONCompletionHandler:^(id jsonDictionary, NSInteger statusCode, NSError *error) {
          
          if (!error) {
              [self updateFinesFromServer];
          } else {
              [Error showUnknownErrorСompletion:nil];
          }
      }];
}

- (void)removeCar:(Car *)car сompletionBlock:(RequestCompletionBlock)completionBlock {
    
    NSNumber *car_id = car.car_id;
    
    [MagicalRecord saveWithBlock:^(NSManagedObjectContext * _Nonnull localContext) {
        [car MR_deleteEntityInContext:localContext];
    } completion:^(BOOL contextDidSave, NSError * _Nullable error) {
        if (completionBlock) {
            completionBlock (nil, nil);
        }
    }];
    
    NSMutableURLRequest *request = [Session DeleteJsonRequestWithUrl:[self vehicleURL] parameters:(NSDictionary *)@[car_id] headers:[self defaultFinesHeaders]];
    
    [Session startTaskWithRequest:request JSONCompletionHandler:^(id jsonDictionary, NSInteger statusCode, NSError *error) {
        
        if (!error) {
            [self updateFinesFromServer];
        } else {
            [Error showUnknownErrorСompletion:nil];
        }
    }];
}

- (void)removeAllCars {
    
    for (int i = 1; i < 100; i++) {
        
        NSMutableURLRequest *request = [Session DeleteJsonRequestWithUrl:[self vehicleURL] parameters:(NSDictionary *)@[[NSString stringWithFormat:@"%d", i]] headers:[self defaultFinesHeaders]];
        
        [Session startTaskWithRequest:request JSONCompletionHandler:^(id jsonDictionary, NSInteger statusCode, NSError *error) {
            
            if (!error) {
                [self updateFinesFromServer];
            }
        }];
    }
}

- (NSString *)vehicleURL {
    return [NSString stringWithFormat:@"%@/vehicle_registrations", finesHost];
}

- (Car *)carFromDictionary:(NSDictionary *)result inContext:(NSManagedObjectContext *)context {
    Car *car = [Car carWithName:[Session safeStringForKey:@"name" fromDictionary:result]regCertificate:[Session safeStringForKey:@"number" fromDictionary:result] regNumber:[Session safeStringForKey:@"vehicleRegistrationNumber" fromDictionary:result] inContext:context];
    car.car_id = [Session safeNumberForKey:@"id" fromDictionary:result];
    return car;
}


#pragma mark - Drivers

- (void)getDriversFromServerWithCompletionBlock:(RequestCompletionBlock)completionBlock {
    
    NSMutableURLRequest *request = [Session GetRequestWithUrl:[self driverURL] headers:[self defaultFinesHeaders]];
    
    [Session startTaskWithRequest:request JSONCompletionHandler:^(id jsonObject, NSInteger statusCode, NSError *error) {
        
        if (!error && jsonObject) {
            for (NSDictionary *result in (NSArray *)jsonObject) {
                [MagicalRecord saveWithBlockAndWait:^(NSManagedObjectContext * _Nonnull localContext) {
                    [self driverFromDictionary:result inContext:localContext];
                }];
            }
            [[NSManagedObjectContext MR_defaultContext] MR_saveToPersistentStoreAndWait];
        }
        
        if (completionBlock) {
            completionBlock(nil, error);
        }
    }];
}

- (void)addDriverWithName:(NSString *)name
           drivingLicense:(NSString *)drivingLicense
          сompletionBlock:(RequestCompletionBlock)completionBlock {
    
      __block Driver *driver;
      [MagicalRecord saveWithBlockAndWait:^(NSManagedObjectContext * _Nonnull localContext) {
          driver = [Driver driverWithName:name numberLicense:drivingLicense inContext:localContext];
          if (completionBlock) {
              completionBlock (driver, nil);
          }
      }];
      [[NSManagedObjectContext MR_defaultContext] MR_saveToPersistentStoreAndWait];
      
      
      NSDictionary *parameters = @{@"number": drivingLicense,
                                   @"name": name};
      
      NSMutableURLRequest *request = [Session PostJsonRequestWithUrl:[self driverURL] parameters:(NSDictionary *)@[parameters] headers:[self defaultFinesHeaders]];
      
      [Session startTaskWithRequest:request JSONCompletionHandler:^(id jsonDictionary, NSInteger statusCode, NSError *error) {
          
          if (!error && jsonDictionary) {
              NSDictionary *dict = jsonDictionary[0];
              driver = [driver MR_inContext:[NSManagedObjectContext MR_defaultContext]];
              driver.driver_id = [Session safeNumberForKey:@"id" fromDictionary:dict];
              [[NSManagedObjectContext MR_defaultContext] MR_saveToPersistentStoreAndWait];
              [self updateFinesFromServer];
          } else {
              [Error showUnknownErrorСompletion:nil];
          }
      }];
}

- (void)updateDriver:(Driver *)driver
            withName:(NSString *)name
      drivingLicense:(NSString *)drivingLicense
     сompletionBlock:(RequestCompletionBlock)completionBlock {
    
    [MagicalRecord saveWithBlockAndWait:^(NSManagedObjectContext * _Nonnull localContext) {
        [driver updateWithName:name numberLicense:drivingLicense inContext:localContext];
        if (completionBlock) {
            completionBlock (driver, nil);
        }
    }];
    [[NSManagedObjectContext MR_defaultContext] MR_saveToPersistentStoreAndWait];
    
    NSDictionary *parameters = @{@"id": driver.driver_id,
                                 @"number": drivingLicense ? drivingLicense : @"",
                                 @"name": name ? name : @""};
    
    NSMutableURLRequest *request = [Session PutJsonRequestWithUrl:[self driverURL] parameters:(NSDictionary *)@[parameters] headers:[self defaultFinesHeaders]];
    
    [Session startTaskWithRequest:request JSONCompletionHandler:^(id jsonDictionary, NSInteger statusCode, NSError *error) {
        
        if (!error) {
            [self updateFinesFromServer];
        } else {
            [Error showUnknownErrorСompletion:nil];
        }
    }];
}

- (void)removeDriver:(Driver *)driver сompletionBlock:(RequestCompletionBlock)completionBlock {
    
    NSNumber *driver_id = driver.driver_id;
    
    [MagicalRecord saveWithBlock:^(NSManagedObjectContext * _Nonnull localContext) {
        [driver MR_deleteEntityInContext:localContext];
    } completion:^(BOOL contextDidSave, NSError * _Nullable error) {
        [self sendUpdateNotificationWithUserInfo:@{@"error" : error ?: [NSNull null]}];
        if (completionBlock) {
            completionBlock (nil, nil);
        }
    }];
    
    NSMutableURLRequest *request = [Session DeleteJsonRequestWithUrl:[self driverURL] parameters:(NSDictionary *)@[driver_id] headers:[self defaultFinesHeaders]];
    
    [Session startTaskWithRequest:request JSONCompletionHandler:^(id jsonDictionary, NSInteger statusCode, NSError *error) {
        
        if (!error) {
            [self updateFinesFromServer];
        } else {
            
        }
    }];
}

- (void)removeAllDrivers {
    
    for (int i = 1; i < 100; i++) {
        
        NSMutableURLRequest *request = [Session DeleteJsonRequestWithUrl:[self driverURL] parameters:(NSDictionary *)@[[NSString stringWithFormat:@"%d", i]] headers:[self defaultFinesHeaders]];
        
        [Session startTaskWithRequest:request JSONCompletionHandler:^(id jsonDictionary, NSInteger statusCode, NSError *error) {
            
            if (!error) {
                [self updateFinesFromServer];
            }
        }];
    }
}

- (NSString *)driverURL {
    return [NSString stringWithFormat:@"%@/driver_licenses", finesHost];
}

- (Driver *)driverFromDictionary:(NSDictionary *)result inContext:(NSManagedObjectContext *)context {
    Driver *driver = [Driver driverWithName:[Session safeStringForKey:@"name" fromDictionary:result] numberLicense:[Session safeStringForKey:@"number" fromDictionary:result] inContext:context];
    driver.driver_id = [Session safeNumberForKey:@"id" fromDictionary:result];
    return driver;
}


#pragma mark - Notifications

- (void)loadNotificationsFromServer {
    
    NSMutableURLRequest *request = [Session GetRequestWithUrl:[NSString stringWithFormat:@"%@/notification-settings", finesHost] headers:[self defaultFinesHeaders]];
    
    [Session startTaskWithRequest:request JSONCompletionHandler:^(id jsonObject, NSInteger statusCode, NSError *error) {
        
        if (!error && jsonObject) {
            for (NSString *notification in jsonObject) {
                [Notification changeNotificationString:notification value:YES];
            }
        }
    }];
}

- (void)sendNotificationsToServer:(NSArray *)notifications {
    
    NSMutableURLRequest *request = [Session PutJsonRequestWithUrl:[NSString stringWithFormat:@"%@/notification-settings", finesHost] parameters:(NSDictionary *)notifications headers:[self defaultFinesHeaders]];
    
    [Session startTaskWithRequest:request JSONCompletionHandler:^(id jsonDictionary, NSInteger statusCode, NSError *error) {
        
    }];
}


#pragma mark - Phone Number

- (NSString *)phoneNumber {
    return [[NSUserDefaults standardUserDefaults] objectForKey:userPhoneNumberService];
}

- (void)setPhoneNumber:(NSString *)phoneNumber {
    [[NSUserDefaults standardUserDefaults] setObject:phoneNumber forKey:userPhoneNumberService];
    [[NSUserDefaults standardUserDefaults] synchronize];
}


#pragma mark - Token

- (NSString *)token {
    return [SSKeychain passwordForService:userTokenService account:self.phoneNumber error:nil];
}

- (void)setToken:(NSString *)token {
    [SSKeychain setPassword:token forService:userTokenService account:self.phoneNumber];
}

- (void)removeToken {
    [SSKeychain deletePasswordForService:userTokenService account:self.phoneNumber];
}

@end
