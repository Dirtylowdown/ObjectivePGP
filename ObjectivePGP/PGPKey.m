//
//  PGPTransferableKey.m
//  ObjectivePGP
//
//  Created by Marcin Krzyzanowski on 13/05/14.
//  Copyright (c) 2014 Marcin Krzyżanowski. All rights reserved.
//

#import "PGPKey.h"
#import "PGPPublicKeyPacket.h"
#import "PGPSecretKeyPacket.h"
#import "PGPUser.h"
#import "PGPSignaturePacket.h"
#import "PGPSignatureSubpacket.h"
#import "PGPPublicSubKeyPacket.h"
#import "PGPSecretSubKeyPacket.m"
#import "PGPSubKey.h"

@implementation PGPKey

- (instancetype) initWithPackets:(NSArray *)packets
{
    if (self = [self init]) {
        [self loadPackets:packets];
    }
    return self;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"%@ primary key: %@",[super description], self.primaryKeyPacket];
}

- (NSMutableArray *)users
{
    if (!_users) {
        _users = [NSMutableArray array];
    }
    return _users;
}

- (NSMutableArray *)subKeys
{
    if (!_subKeys) {
        _subKeys = [NSMutableArray array];
    }
    return _subKeys;
}

- (BOOL)isEncrypted
{
    if (self.type == PGPKeySecret) {
        PGPSecretKeyPacket *secretPacket = self.primaryKeyPacket;
        return secretPacket.isEncrypted;
    }
    return NO;
}

- (PGPKeyType)type
{
    PGPKeyType t = PGPKeyUnknown;

    switch (self.primaryKeyPacket.tag) {
        case PGPPublicKeyPacketTag:
            t = PGPKeyPublic;
            break;
        case PGPSecretKeyPacketTag:
            t = PGPKeySecret;
        default:
            break;
    }

    return t;
}

- (void) loadPackets:(NSArray *)packets
{
    // based on packetlist2structure
    PGPKeyID *primaryKeyID = nil;
    PGPSubKey *subKey      = nil;
    PGPUser *user          = nil;

    for (id <PGPPacket> packet in packets) {
        switch (packet.tag) {
            case PGPPublicKeyPacketTag:
                primaryKeyID = [(PGPPublicKeyPacket *)packet keyID];
                self.primaryKeyPacket = packet;
                break;
            case PGPSecretKeyPacketTag:
                primaryKeyID = [(PGPSecretKeyPacket *)packet keyID];
                self.primaryKeyPacket = packet;
                break;
            case PGPUserIDPacketTag:
            case PGPUserAttributePacketTag:
                user = [[PGPUser alloc] initWithPacket:(PGPUserIDPacket *)packet];
                [self.users addObject:user];
                break;
            case PGPPublicSubkeyPacketTag:
            case PGPSecretSubkeyPacketTag:
                user = nil;
                subKey = [[PGPSubKey alloc] initWithPacket:packet];
                [self.subKeys addObject:packet];
                break;
            case PGPSignaturePacketTag:
            {
                PGPSignaturePacket *signaturePacket = packet;
                switch (signaturePacket.type) {
                    case PGPSignatureGenericCertificationUserIDandPublicKey:
                    case PGPSignatureCasualCertificationUserIDandPublicKey:
                    case PGPSignaturePositiveCertificationUserIDandPublicKey:
                    case PGPSignaturePersonalCertificationUserIDandPublicKey:
                        if (!user) {
                            continue;
                        }
                        if ([signaturePacket.issuerKeyID isEqual:primaryKeyID]) {
                            user.revocationSignatures = [user.revocationSignatures arrayByAddingObject:packet];
                        } else {
                            user.otherSignatures = [user.otherSignatures arrayByAddingObject:packet];
                        }
                        break;
                    case PGPSignatureCertificationRevocation:
                        if (user) {
                            user.revocationSignatures = [user.revocationSignatures arrayByAddingObject:packet];
                        } else {
                            [self.directSignatures addObject:packet];
                        }
                        break;
                    case PGPSignatureDirectlyOnKey:
                        [self.directSignatures addObject:packet];
                        break;
                    case PGPSignatureSubkeyBinding:
                        if (!subKey) {
                            continue;
                        }
                        subKey.bindingSignature = packet;
                        break;
                    case PGPSignatureKeyRevocation:
                        self.revocationSignature = packet;
                        break;
                    case PGPSignatureSubkeyRevocation:
                        if (!subKey) {
                            continue;
                        }
                        subKey.revocationSignature = packet;
                        break;
                    default:
                        break;
                }
            }
                break;
            default:
                break;
        }
    }
}

- (BOOL) decrypt:(NSString *)passphrase error:(NSError *__autoreleasing *)error
{
    BOOL ret = NO;
    for (id <PGPPacket> packet in [self allKeyPackets]) {
        if (packet.tag == PGPSecretKeyPacketTag) {
            PGPSecretKeyPacket *secretKeyPacket = packet;
            ret = [secretKeyPacket decrypt:passphrase error:error];
        } else if (packet.tag == PGPSecretSubkeyPacketTag) {
            PGPSecretSubKeyPacket *secretSubKeyPacket = packet;
            ret = [secretSubKeyPacket decrypt:passphrase error:error];
        }
    }
    return ret;
}

#pragma mark - Private

- (NSArray *)allKeyPackets
{
    NSMutableArray *arr = [NSMutableArray arrayWithObject:self.primaryKeyPacket];
    for (PGPSubKey *subKey in self.subKeys) {
        [arr addObject:subKey.keyPacket];
    }
    return [arr copy];
}

@end