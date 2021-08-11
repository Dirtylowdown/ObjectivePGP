//
//  Copyright (c) Marcin Krzyżanowski. All rights reserved.
//
//  THIS SOURCE CODE AND ANY ACCOMPANYING DOCUMENTATION ARE PROTECTED BY
//  INTERNATIONAL COPYRIGHT LAW. USAGE IS BOUND TO THE LICENSE AGREEMENT.
//  This notice may not be removed from this file.
//

//  5.1.  Public-Key Encrypted Session Key Packets (Tag 1)

#import "PGPPublicKeyEncryptedSessionKeyPacket.h"
#import "PGPPublicKeyEncryptedSessionKeyParams.h"
#import "NSData+PGPUtils.h"
#import "NSArray+PGPUtils.h"
#import "PGPCryptoUtils.h"
#import "PGPFingerprint.h"
#import "PGPKeyID.h"
#import "PGPMPI.h"
#import "PGPPKCSEme.h"
#import "PGPPublicKeyPacket.h"
#import "PGPRSA.h"
#import "PGPEC.h"
#import "PGPElgamal.h"
#import "PGPSecretKeyPacket.h"
#import "PGPSecretKeyPacket+Private.h"
#import "PGPMacros+Private.h"
#import "PGPFoundation.h"
#import "NSData+PGPUtils.h"
#import "NSMutableData+PGPUtils.h"
#import "PGPLogging.h"

#import <openssl/err.h>
#import <openssl/ssl.h>
#import <openssl/evp.h>
#import <openssl/aes.h>
#import <openssl/ec.h>
#import <openssl/ecdh.h>
#import <openssl/ecdsa.h>
#import <openssl/ecerr.h>

NS_ASSUME_NONNULL_BEGIN

@interface PGPPublicKeyEncryptedSessionKeyPacket ()

@property (nonatomic, copy) PGPPublicKeyEncryptedSessionKeyParams *parameters;

@end

@implementation PGPPublicKeyEncryptedSessionKeyPacket

- (instancetype)init {
    if (self = [super init]) {
        _version = 3;
        _publicKeyAlgorithm = PGPPublicKeyAlgorithmRSA;
        _parameters = [[PGPPublicKeyEncryptedSessionKeyParams alloc] init];
    }
    return self;
}

- (PGPPacketTag)tag {
    return PGPPublicKeyEncryptedSessionKeyPacketTag; // 1
}

- (NSUInteger)parsePacketBody:(NSData *)packetBody error:(NSError * __autoreleasing _Nullable *)error {
    NSUInteger position = [super parsePacketBody:packetBody error:error];

    // - A one-octet number giving the version number of the packet type. The currently defined value for packet version is 3.
    [packetBody getBytes:&_version range:(NSRange){position, 1}];
    NSAssert(self.version == 3, @"The currently defined value for packet version is 3");
    position = position + 1;

    // - An eight-octet number that gives the Key ID of the public key
    self.keyID = [[PGPKeyID alloc] initWithLongKey:[packetBody subdataWithRange:(NSRange){position, 8}]];
    NSAssert(self.keyID, @"Missing KeyID");
    position = position + 8;

    // - A one-octet number giving the public-key algorithm used.
    [packetBody getBytes:&_publicKeyAlgorithm range:(NSRange){position, 1}];
    position = position + 1;

    // - A string of octets that is the encrypted session key.  This
    //   string takes up the remainder of the packet, and its contents are
    //   dependent on the public-key algorithm used.
    //   RSA 1 MPI
    //   Elgamal 2 MPI

    let encryptedMPI_Data = [packetBody subdataWithRange:(NSRange){position, packetBody.length - position}];

    switch (self.publicKeyAlgorithm) {
        case PGPPublicKeyAlgorithmRSAEncryptOnly:
        case PGPPublicKeyAlgorithmRSA: {
            // MPI of RSA encrypted value m**e mod n.
            let encryptedMPI_M = [[PGPMPI alloc] initWithMPIData:encryptedMPI_Data identifier:PGPMPIdentifierM atPosition:0];
            position = position + encryptedMPI_M.packetLength;

            self.parameters.MPIs = @[encryptedMPI_M];
        } break;
        case PGPPublicKeyAlgorithmElgamalEncryptorSign:
        case PGPPublicKeyAlgorithmElgamal: {
            // MPI of Elgamal (Diffie-Hellman) value g**k mod p.
            let MPI_G_K = [[PGPMPI alloc] initWithMPIData:encryptedMPI_Data identifier:PGPMPIdentifierG atPosition:0];
            position = position + MPI_G_K.packetLength;
            // MPI of Elgamal (Diffie-Hellman) value m * y**k mod p.
            let encryptedMPI_M = [[PGPMPI alloc] initWithMPIData:encryptedMPI_Data identifier:PGPMPIdentifierM atPosition:0 + MPI_G_K.packetLength];
            position = position + encryptedMPI_M.packetLength;

            self.parameters.MPIs = @[MPI_G_K, encryptedMPI_M];
        } break;
        case PGPPublicKeyAlgorithmECDH: {
            // https://tools.ietf.org/html/rfc6637#section-10
            // Algorithm-Specific Fields for ECDH
            // an MPI of an EC point representing an ephemeral public key
            // MPI containing the ephemeral key used to establish the shared secret
            let MPI_V = [[PGPMPI alloc] initWithMPIData:packetBody identifier:PGPMPIdentifierV atPosition:position];
            position = position + MPI_V.packetLength;

            // a one-octet size
            UInt8 keySize = 0;
            [packetBody getBytes:&keySize range:(NSRange){position, 1}];
            position = position + 1;

            // followed by an encoded symmetric key (encoding: https://tools.ietf.org/html/rfc6637#section-8)
            // ECDH Symmetric Key
            let encodedSymmetricKey = [packetBody subdataWithRange:(NSRange){position, keySize}];
            position = position + keySize;

            self.parameters.MPIs = @[MPI_V];
            self.parameters.symmetricKey = encodedSymmetricKey;
        } break;
        case PGPPublicKeyAlgorithmECDSA:
        case PGPPublicKeyAlgorithmEdDSA:
        case PGPPublicKeyAlgorithmDSA:
        case PGPPublicKeyAlgorithmRSASignOnly:
        case PGPPublicKeyAlgorithmDiffieHellman:
        case PGPPublicKeyAlgorithmPrivate1:
        case PGPPublicKeyAlgorithmPrivate2:
        case PGPPublicKeyAlgorithmPrivate3:
        case PGPPublicKeyAlgorithmPrivate4:
        case PGPPublicKeyAlgorithmPrivate5:
        case PGPPublicKeyAlgorithmPrivate6:
        case PGPPublicKeyAlgorithmPrivate7:
        case PGPPublicKeyAlgorithmPrivate8:
        case PGPPublicKeyAlgorithmPrivate9:
        case PGPPublicKeyAlgorithmPrivate10:
        case PGPPublicKeyAlgorithmPrivate11:
            NSAssert(false, @"ESK has invalid format.");
            break;
    }

    return position;
}

// Helper
- (nullable PGPMPI *)parameterMPI:(NSString *)identifier {
    return [[self.parameters.MPIs pgp_objectsPassingTest:^BOOL(PGPMPI *obj, BOOL *stop) {
        *stop = PGPEqualObjects(obj.identifier, identifier);
        return *stop;
    }] firstObject];
}

// encryption update self.encryptedMPIs
- (BOOL)encrypt:(PGPPublicKeyPacket *)publicKeyPacket sessionKeyData:(NSData *)sessionKeyData sessionKeyAlgorithm:(PGPSymmetricAlgorithm)sessionKeyAlgorithm error:(NSError * __autoreleasing _Nullable *)error {
    let mData = [NSMutableData data];

    //    The value "m" in the above formulas is derived from the session key
    //    as follows.  First, the session key is prefixed with a one-octet
    //    algorithm identifier that specifies the symmetric encryption
    //    algorithm used to encrypt the following Symmetrically Encrypted Data
    //    Packet.  Then a two-octet checksum is appended, which is equal to the
    //    sum of the preceding session key octets, not including the algorithm
    //    identifier, modulo 65536.  This value is then encoded as described in
    //    PKCS#1 block encoding EME-PKCS1-v1_5 in Section 7.2.1 of [RFC3447] to
    //    form the "m" value used in the formulas above.  See Section 13.1 of
    //    this document for notes on OpenPGP's use of PKCS#1.

    [mData appendBytes:&sessionKeyAlgorithm length:1];

    [mData appendData:sessionKeyData]; // keySize

    UInt16 checksum = [sessionKeyData pgp_Checksum];
    checksum = CFSwapInt16HostToBig(checksum);
    [mData appendBytes:&checksum length:2];


    PGPMPI *modulusMPI = nil;
    switch (self.publicKeyAlgorithm) {
        case PGPPublicKeyAlgorithmRSAEncryptOnly:
        case PGPPublicKeyAlgorithmRSASignOnly:
        case PGPPublicKeyAlgorithmRSA:
            modulusMPI = [publicKeyPacket publicMPI:PGPMPIdentifierN];
            break;
        // case PGPPublicKeyAlgorithmDSA:
        case PGPPublicKeyAlgorithmElgamal:
        case PGPPublicKeyAlgorithmElgamalEncryptorSign:
            modulusMPI = [publicKeyPacket publicMPI:PGPMPIdentifierP];
            break;
        default:
            break;
    }

    if (!modulusMPI) {
        if (error) {
            *error = [NSError errorWithDomain:PGPErrorDomain code:PGPErrorGeneral userInfo:@{NSLocalizedDescriptionKey: @"Cannot encrypt. Missing required MPI. Invalid key."}];
        }
        return NO;
    }

    unsigned int k = (unsigned int)modulusMPI.bigNum.bytesCount;
    let mEMEEncodedData = [PGPPKCSEme encodeMessage:mData keyModulusLength:k error:error];
    self.parameters.MPIs = [publicKeyPacket encryptData:mEMEEncodedData withPublicKeyAlgorithm:self.publicKeyAlgorithm];
    return YES;
}

- (nullable NSData *)decodeElgamal:(PGPSecretKeyPacket *)secretKeyPacket error:(NSError * __autoreleasing _Nullable *)error {
    // encrypted m value
    let encryptedM = [[self parameterMPI:PGPMPIdentifierM] bodyData];

    // encryptedMPIs has g^k as PGPMPIdentifierG
    let g_k_mpi = [self parameterMPI:PGPMPIdentifierG];
    if (!g_k_mpi) {
        PGPLogWarning(@"Invalid key, can't decrypt. Missing g^k.");
        return nil;
    }

    let mEMEEncoded = [PGPElgamal privateDecrypt:encryptedM withSecretKeyPacket:secretKeyPacket gk:g_k_mpi];
    let decoded = [PGPPKCSEme decodeMessage:mEMEEncoded error:error];
    if (error && *error) {
        return nil;
    }

    return decoded;
}


- (nullable NSData *)decodeRSA:(PGPSecretKeyPacket *)secretKeyPacket error:(NSError * __autoreleasing _Nullable *)error {
    // encrypted m value
    let encryptedM = [[self parameterMPI:PGPMPIdentifierM] bodyData];
    // decrypted m value
    let mEMEEncoded = [PGPRSA privateDecrypt:encryptedM withSecretKeyPacket:secretKeyPacket];

    let decoded = [PGPPKCSEme decodeMessage:mEMEEncoded error:error];
    if (error && *error) {
        return nil;
    }

    return decoded;
}


- (nullable NSData *)decodeECC:(PGPSecretKeyPacket *)secretKeyPacket error:(NSError * __autoreleasing _Nullable *)error {
    let keyAlgorithm = secretKeyPacket.publicKeyAlgorithm;
    let C = self.parameters.symmetricKey; // C aka ECDH Symmetric Key
    let V = [[self parameterMPI:PGPMPIdentifierV] bodyData]; // V aka encrypted

    // - Generate ECDHE secret from private key and public part of ephemeral key
    let sharedKey = [PGPEC generatePrivateEphemeralKeyWith:V andSecretKeyPacket:secretKeyPacket];

    // - The KDF parameters https://datatracker.ietf.org/doc/html/rfc6637#section-8
    let params = [NSMutableData data];
    // one-octet size of the following field. the octets representing a curve OID
    [params pgp_appendData:[secretKeyPacket.curveOID export:error]];
    // one-octet public key algorithm ID
    [params appendBytes:&keyAlgorithm length:1];
    // KDF params
    [params pgp_appendData:[secretKeyPacket.curveKDFParameters export:error]];
    // 20 octets representing the UTF-8 encoding of the string "Anonymous Sender    "
    const unsigned char anonymous_sender[] = {0x41, 0x6E, 0x6F, 0x6E, 0x79, 0x6D, 0x6F, 0x75, 0x73, 0x20, 0x53, 0x65, 0x6E, 0x64, 0x65, 0x72, 0x20, 0x20, 0x20, 0x20};
    [params appendBytes:anonymous_sender length:20];
    // 20 octets representing a recipient encryption subkey or a master key fingerprint
    [params pgp_appendData:secretKeyPacket.fingerprint.hashedData];
    {
        // KDF produces a symmetric key that is used as a key-encryption key (KEK)
        // https://datatracker.ietf.org/doc/html/rfc6637#section-7
        const unsigned char prefix_bytes[] = {0x00, 0x00, 0x00, 0x01};
        let input =  [NSMutableData dataWithBytes:prefix_bytes length:4];
        [input pgp_appendData:sharedKey];
        [input pgp_appendData:params];
        // truncated KEK
        let KEK = [[input pgp_HashedWithAlgorithm:secretKeyPacket.curveKDFParameters.hashAlgorithm] subdataWithRange:NSMakeRange(0, [PGPCryptoUtils keySizeOfSymmetricAlgorithm:secretKeyPacket.curveKDFParameters.symmetricAlgorithm])];
        {
            // Key Unwrap https://datatracker.ietf.org/doc/html/rfc3394#section-2.2.2
            unsigned int unwrapped_length = (unsigned int)C.length - sizeof(UInt64);
            if (unwrapped_length <= 0) {
                return nil;
            }

            unsigned char *unwrapped_buf = OPENSSL_secure_malloc(unwrapped_length);
            pgp_defer {
                OPENSSL_secure_free(unwrapped_buf);
            };

            AES_KEY aes_key;
            AES_set_decrypt_key(KEK.bytes, (int)KEK.length * sizeof(UInt64), &aes_key);

            if (AES_unwrap_key(&aes_key, NULL, unwrapped_buf, C.bytes, (int)C.length) <= 0) {
                memset(&aes_key, 0, sizeof(AES_KEY));
                return nil;
            }

            let decodedPadded = [NSData dataWithBytes:unwrapped_buf length:unwrapped_length];

            // Remove PKCS5 padding
            var decoded = decodedPadded;
            let c = unwrapped_buf[unwrapped_length - 1];
            if (c >= 1) {
                decoded = [decodedPadded subdataWithRange:NSMakeRange(0, unwrapped_length - c)];
            }
            memset(&aes_key, 0, sizeof(AES_KEY));
            return decoded;
        }
    }
    return nil;
}

- (nullable NSData *)decryptSessionKeyData:(PGPSecretKeyPacket *)secretKeyPacket sessionKeyAlgorithm:(PGPSymmetricAlgorithm *)sessionKeyAlgorithm error:(NSError * __autoreleasing _Nullable *)error {
    NSAssert(!secretKeyPacket.isEncryptedWithPassphrase, @"Secret key can't be decrypted");

    if (secretKeyPacket.publicKeyAlgorithm != self.publicKeyAlgorithm) {
        if (error) {
            *error = [NSError errorWithDomain:PGPErrorDomain code:0 userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Decryption error (algorithm mismatch)"] }];
        }
        return nil;
    }

    let _Nullable secretKeyKeyID = [[PGPKeyID alloc] initWithFingerprint:secretKeyPacket.fingerprint];
    if (!secretKeyKeyID || !PGPEqualObjects(self.keyID, secretKeyKeyID)) {
        if (error) {
            *error = [NSError errorWithDomain:PGPErrorDomain code:0 userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Invalid secret key used to decrypt session key, expected %@, got %@", self.keyID, secretKeyKeyID] }];
        }
        return nil;
    }

    NSData * _Nullable decoded = nil;
    switch (self.publicKeyAlgorithm) {
        case PGPPublicKeyAlgorithmECDH:
            decoded = [self decodeECC:secretKeyPacket error:error];
            break;
        case PGPPublicKeyAlgorithmRSA:
        case PGPPublicKeyAlgorithmRSASignOnly:
        case PGPPublicKeyAlgorithmRSAEncryptOnly:
            decoded = [self decodeRSA:secretKeyPacket error:error];
            break;
        case PGPPublicKeyAlgorithmElgamal:
        case PGPPublicKeyAlgorithmElgamalEncryptorSign:
            decoded = [self decodeElgamal:secretKeyPacket error:error];
            break;
        default:
            NSAssert(NO, @"Unsupported. Unexpected.");
            return nil;
    }

    NSUInteger position = 0;
    PGPSymmetricAlgorithm sessionKeyAlgorithmRead = PGPSymmetricPlaintext;
    [decoded getBytes:&sessionKeyAlgorithmRead range:(NSRange){position, 1}];
    NSAssert(sessionKeyAlgorithmRead < PGPSymmetricMax, @"Invalid algorithm");
    if (sessionKeyAlgorithm) {
        *sessionKeyAlgorithm = sessionKeyAlgorithmRead;
    }
    position = position + 1;

    NSUInteger sessionKeySize = [PGPCryptoUtils keySizeOfSymmetricAlgorithm:sessionKeyAlgorithmRead];
    if (sessionKeySize == NSNotFound) {
        if (error) {
            *error = [NSError errorWithDomain:PGPErrorDomain code:0 userInfo:@{ NSLocalizedDescriptionKey: @"Invalid session key size" }];
        }
        return nil;
    }

    let sessionKeyData = [decoded subdataWithRange:(NSRange){position, sessionKeySize}];
    position = position + sessionKeySize;

    UInt16 checksum = 0;
    [decoded getBytes:&checksum range:(NSRange){position, 2}];
    checksum = CFSwapInt16BigToHost(checksum);

    // validate checksum
    UInt16 calculatedChecksum = [sessionKeyData pgp_Checksum];
    if (calculatedChecksum != checksum) {
        if (error) {
            *error = [NSError errorWithDomain:PGPErrorDomain code:0 userInfo:@{ NSLocalizedDescriptionKey: @"Invalid session key, checksum mismatch" }];
        }
        return nil;
    }
    return sessionKeyData;
}

#pragma mark - PGPExportable

- (nullable NSData *)export:(NSError * __autoreleasing _Nullable *)error {
    let bodyData = [NSMutableData data];

    [bodyData appendBytes:&_version length:1]; // 1
    [bodyData appendData:[self.keyID export:nil]]; // 8
    [bodyData appendBytes:&_publicKeyAlgorithm length:1]; // 1

    switch (self.publicKeyAlgorithm) {
        case PGPPublicKeyAlgorithmRSAEncryptOnly:
        case PGPPublicKeyAlgorithmRSA: {
            let exportedMPIData = [[self parameterMPI:PGPMPIdentifierM] exportMPI];
            if (!exportedMPIData) {
                if (error) {
                    *error = [NSError errorWithDomain:PGPErrorDomain code:PGPErrorGeneral userInfo:@{NSLocalizedDescriptionKey: @"Cannot export session key packet"}];
                }
                return nil;
            }
            [bodyData appendData:exportedMPIData]; // m
        }
        break;
        case PGPPublicKeyAlgorithmElgamal: {
            let exportedMPI_GData = [[self parameterMPI:PGPMPIdentifierG] exportMPI];
            let exportedMPI_MData = [[self parameterMPI:PGPMPIdentifierM] exportMPI];
            if (!exportedMPI_GData || !exportedMPI_MData) {
                if (error) {
                    *error = [NSError errorWithDomain:PGPErrorDomain code:PGPErrorGeneral userInfo:@{NSLocalizedDescriptionKey: @"Cannot export session key packet"}];
                }
                return nil;
            }
            [bodyData appendData:exportedMPI_GData]; // g
            [bodyData appendData:exportedMPI_MData]; // m
        }
        break;
        case PGPPublicKeyAlgorithmDSA:
        case PGPPublicKeyAlgorithmRSASignOnly:
        case PGPPublicKeyAlgorithmECDH:
        case PGPPublicKeyAlgorithmECDSA:
        case PGPPublicKeyAlgorithmElgamalEncryptorSign:
        case PGPPublicKeyAlgorithmDiffieHellman:
        // case PGPPublicKeyAlgorithmEdDSA:
        case PGPPublicKeyAlgorithmPrivate1:
        case PGPPublicKeyAlgorithmPrivate2:
        case PGPPublicKeyAlgorithmPrivate3:
        case PGPPublicKeyAlgorithmPrivate4:
        case PGPPublicKeyAlgorithmPrivate5:
        case PGPPublicKeyAlgorithmPrivate6:
        case PGPPublicKeyAlgorithmPrivate7:
        case PGPPublicKeyAlgorithmPrivate8:
        case PGPPublicKeyAlgorithmPrivate9:
        case PGPPublicKeyAlgorithmPrivate10:
        case PGPPublicKeyAlgorithmPrivate11:
            NSAssert(false, @"Cannot export ESK. Invalid packet.");
            break;
    }

    return [PGPPacket buildPacketOfType:self.tag withBody:^NSData * {
        return bodyData;
    }];
}

#pragma mark - isEqual

- (BOOL)isEqual:(id)other {
    if (self == other) { return YES; }
    if ([super isEqual:other] && [other isKindOfClass:self.class]) {
        return [self isEqualToSessionKeyPacket:other];
    }
    return NO;
}

- (BOOL)isEqualToSessionKeyPacket:(PGPPublicKeyEncryptedSessionKeyPacket *)packet {
    return self.version == packet.version &&
           self.publicKeyAlgorithm == packet.publicKeyAlgorithm &&
           PGPEqualObjects(self.keyID, packet.keyID) &&
           PGPEqualObjects(self.parameters, packet.parameters);
}

- (NSUInteger)hash {
    NSUInteger prime = 31;
    NSUInteger result = [super hash];
    result = prime * result + self.version;
    result = prime * result + self.publicKeyAlgorithm;
    result = prime * result + self.keyID.hash;
    result = prime * result + self.parameters.hash;
    return result;
}

#pragma mark - NSCopying

- (instancetype)copyWithZone:(nullable NSZone *)zone {
    let duplicate = PGPCast([super copyWithZone:zone], PGPPublicKeyEncryptedSessionKeyPacket);
    PGPAssertClass(duplicate, PGPPublicKeyEncryptedSessionKeyPacket);
    duplicate.version = self.version;
    duplicate.publicKeyAlgorithm = self.publicKeyAlgorithm;
    duplicate.keyID = self.keyID;
    duplicate.parameters = self.parameters;
    return duplicate;
}

@end

NS_ASSUME_NONNULL_END
