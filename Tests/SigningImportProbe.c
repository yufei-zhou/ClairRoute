// Offline compatibility probe: imports generated fixtures into memory only.
// Passing NULL for importKeychain prevents keychain persistence (SDK contract).
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static CFDataRef readData(const char *path) {
    FILE *file = fopen(path, "rb");
    if (!file) exit(2);
    unsigned char bytes[32768];
    size_t length = fread(bytes, 1, sizeof(bytes), file);
    if (ferror(file) || !feof(file)) exit(2);
    fclose(file);
    return CFDataCreate(NULL, bytes, (CFIndex)length);
}

int main(int argc, const char **argv) {
    if (argc != 4) return 2;
    CFDataRef data = readData(argv[1]);
    CFDataRef passwordData = readData(argv[2]);
    CFStringRef password = CFStringCreateFromExternalRepresentation(NULL, passwordData, kCFStringEncodingUTF8);
    if (!password) return 2;
    SecExternalFormat format = strcmp(argv[3], "explicit") == 0 ? kSecFormatPKCS12 : kSecFormatUnknown;
    SecExternalItemType type = kSecItemTypeUnknown;
    SecKeyImportExportParameters parameters = {0};
    parameters.version = SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION;
    parameters.passphrase = password;
    CFArrayRef items = NULL;
    OSStatus status = SecKeychainItemImport(data, CFSTR("identity.p12"), &format, &type, 0,
                                          &parameters, NULL, &items);
    CFIndex count = items ? CFArrayGetCount(items) : 0;
    printf("status=%d items=%ld format=%u\n", (int)status, (long)count, (unsigned)format);
    if (items) CFRelease(items);
    CFRelease(password); CFRelease(passwordData); CFRelease(data);
    return status == errSecSuccess && count > 0 ? 0 : 1;
}
