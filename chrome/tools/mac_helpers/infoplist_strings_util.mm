// Copyright (c) 2009 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Helper tool that is built and run during a build to pull strings from
// the GRD files and generate the InfoPlist.strings files needed for
// Mac OS X app bundles.

#import <Foundation/Foundation.h>

#include <stdio.h>
#include <unistd.h>

#include "base/data_pack.h"
#include "base/file_path.h"
#include "base/scoped_nsautorelease_pool.h"
#include "base/scoped_ptr.h"
#include "base/string_piece.h"
#include "base/string_util.h"
#include "grit/chromium_strings.h"

namespace {

NSString* ApplicationVersionString(const char* version_file_path) {
  NSError* error = nil;
  NSString* path_string = [NSString stringWithUTF8String:version_file_path];
  NSString* version_file =
      [NSString stringWithContentsOfFile:path_string
                                encoding:NSUTF8StringEncoding
                                   error:&error];
  if (!version_file || error) {
    fprintf(stderr, "Failed to load version file: %s\n",
            [[error description] UTF8String]);
    return nil;
  }

  int major = 0, minor = 0, build = 0, patch = 0;
  NSScanner* scanner = [NSScanner scannerWithString:version_file];
  if ([scanner scanString:@"MAJOR=" intoString:nil] &&
      [scanner scanInt:&major] &&
      [scanner scanString:@"MINOR=" intoString:nil] &&
      [scanner scanInt:&minor] &&
      [scanner scanString:@"BUILD=" intoString:nil] &&
      [scanner scanInt:&build] &&
      [scanner scanString:@"PATCH=" intoString:nil] &&
      [scanner scanInt:&patch]) {
    return [NSString stringWithFormat:@"%d.%d.%d.%d",
            major, minor, build, patch];
  }
  fprintf(stderr, "Failed to parse version file\n");
  return nil;
}

base::DataPack* LoadResourceDataPack(const char* dir_path,
                                     const char* branding_strings_name,
                                     const char* locale_name) {
  base::DataPack* resource_pack = NULL;

  NSString* resource_path = [NSString stringWithFormat:@"%s/%s_%s.pak",
                             dir_path, branding_strings_name, locale_name];
  if (resource_path) {
    FilePath resources_pak_path([resource_path fileSystemRepresentation]);
    resource_pack = new base::DataPack;
    bool success = resource_pack->Load(resources_pak_path);
    if (!success) {
      delete resource_pack;
      resource_pack = NULL;
    }
  }

  return resource_pack;
}

NSString* LoadStringFromDataPack(base::DataPack* data_pack,
                                 const char* data_pack_lang,
                                 uint32_t resource_id,
                                 const char* resource_id_str) {
  NSString* result = nil;
  StringPiece data;
  if (data_pack->Get(resource_id, &data)) {
    // Data pack encodes strings as UTF16.
    result =
        [[[NSString alloc] initWithBytes:data.data()
                                  length:data.length()
                                encoding:NSUTF16LittleEndianStringEncoding]
         autorelease];
  }
  if (!result) {
    fprintf(stderr, "ERROR: failed to load string %s for lang %s\n",
            resource_id_str, data_pack_lang);
    exit(1);
  }
  return result;
}

// Escape quotes, newlines, etc so there are no errors when the strings file
// is parsed.
NSString* EscapeForStringsFileValue(NSString* str) {
  NSMutableString* worker = [NSMutableString stringWithString:str];

  // Since this is a build tool, we don't really worry about making this
  // the most efficient code.

  // Backslash first since we need to do it before we put in all the others
  [worker replaceOccurrencesOfString:@"\\"
                          withString:@"\\\\"
                             options:NSLiteralSearch
                               range:NSMakeRange(0, [worker length])];
  // Now the rest of them.
  [worker replaceOccurrencesOfString:@"\n"
                          withString:@"\\n"
                             options:NSLiteralSearch
                               range:NSMakeRange(0, [worker length])];
  [worker replaceOccurrencesOfString:@"\r"
                          withString:@"\\r"
                             options:NSLiteralSearch
                               range:NSMakeRange(0, [worker length])];
  [worker replaceOccurrencesOfString:@"\t"
                          withString:@"\\t"
                             options:NSLiteralSearch
                               range:NSMakeRange(0, [worker length])];
  [worker replaceOccurrencesOfString:@"\""
                          withString:@"\\\""
                             options:NSLiteralSearch
                               range:NSMakeRange(0, [worker length])];

  return [[worker copy] autorelease];
}

// The valid types for the -t arg
const char* kAppType_Main = "main";  // Main app
const char* kAppType_Helper = "helper";  // Helper app

}  // namespace

int main(int argc, char* const argv[]) {
  base::ScopedNSAutoreleasePool autorelease_pool;

  const char* version_file_path = NULL;
  const char* grit_output_dir = NULL;
  const char* branding_strings_name = NULL;
  const char* output_dir = NULL;
  const char* app_type = kAppType_Main;

  // Process the args
  int ch;
  while ((ch = getopt(argc, argv, "t:v:g:b:o:")) != -1) {
    switch (ch) {
      case 't':
        app_type = optarg;
        break;
      case 'v':
        version_file_path = optarg;
        break;
      case 'g':
        grit_output_dir = optarg;
        break;
      case 'b':
        branding_strings_name = optarg;
        break;
      case 'o':
        output_dir = optarg;
        break;
      default:
        fprintf(stderr, "ERROR: bad command line arg\n");
        exit(1);
        break;
    }
  }
  argc -= optind;
  argv += optind;

#define CHECK_ARG(a, b) \
  do { \
    if ((a)) { \
      fprintf(stderr, "ERROR: " b "\n"); \
      exit(1); \
    } \
  } while (false)

  // Check our args
  CHECK_ARG(!version_file_path, "Missing VERSION file path");
  CHECK_ARG(!grit_output_dir, "Missing grit output dir path");
  CHECK_ARG(!output_dir, "Missing path to write InfoPlist.strings files");
  CHECK_ARG(!branding_strings_name, "Missing branding strings file name");
  CHECK_ARG(argc == 0, "Missing language list");
  CHECK_ARG((strcmp(app_type, kAppType_Main) != 0 &&
             strcmp(app_type, kAppType_Helper) != 0),
            "Unknown app type");

  char* const* lang_list = argv;
  int lang_list_count = argc;

  // Parse the version file and build our string
  NSString* version_string = ApplicationVersionString(version_file_path);
  if (!version_string) {
    fprintf(stderr, "ERROR: failed to get a version string");
    exit(1);
  }

  NSFileManager* fm = [NSFileManager defaultManager];

  for (int loop = 0; loop < lang_list_count; ++loop) {
    const char* cur_lang = lang_list[loop];

    // Open the branded string pak file
    scoped_ptr<base::DataPack> branded_data_pack(
        LoadResourceDataPack(grit_output_dir,
                             branding_strings_name,
                             cur_lang));
    if (branded_data_pack.get() == NULL) {
      fprintf(stderr, "ERROR: Failed to load branded pak for language: %s\n",
              cur_lang);
      exit(1);
    }

    uint32_t name_id = IDS_PRODUCT_NAME;
    const char* name_id_str = "IDS_PRODUCT_NAME";
    uint32_t short_name_id = IDS_SHORT_PRODUCT_NAME;
    const char* short_name_id_str = "IDS_SHORT_PRODUCT_NAME";
    if (strcmp(app_type, kAppType_Helper) == 0) {
      name_id = IDS_HELPER_NAME;
      name_id_str = "IDS_HELPER_NAME";
      short_name_id = IDS_SHORT_HELPER_NAME;
      short_name_id_str = "IDS_SHORT_HELPER_NAME";
    }

    // Fetch the strings
    NSString* name =
          LoadStringFromDataPack(branded_data_pack.get(), cur_lang,
                                 name_id, name_id_str);
    NSString* short_name =
          LoadStringFromDataPack(branded_data_pack.get(), cur_lang,
                                 short_name_id, short_name_id_str);
    NSString* copyright =
        LoadStringFromDataPack(branded_data_pack.get(), cur_lang,
                               IDS_ABOUT_VERSION_COPYRIGHT,
                               "IDS_ABOUT_VERSION_COPYRIGHT");

    // For now, assume this is ok for all languages. If we need to, this could
    // be moved into generated_resources.grd and fetched.
    NSString *get_info = [NSString stringWithFormat:@"%@ %@, %@",
                          name, version_string, copyright];

    // Generate the InfoPlist.strings file contents
    NSString* strings_file_contents_string =
        [NSString stringWithFormat:
          @"CFBundleDisplayName = \"%@\";\n"
          @"CFBundleGetInfoString = \"%@\";\n"
          @"CFBundleName = \"%@\";\n"
          @"NSHumanReadableCopyright = \"%@\";\n",
          EscapeForStringsFileValue(name),
          EscapeForStringsFileValue(get_info),
          EscapeForStringsFileValue(short_name),
          EscapeForStringsFileValue(copyright)];

    // We set up Xcode projects expecting strings files to be UTF8, so make
    // sure we write the data in that form.  When Xcode copies them it will
    // put them final runtime encoding.
    NSData* strings_file_contents_utf8 =
        [strings_file_contents_string dataUsingEncoding:NSUTF8StringEncoding];

    if ([strings_file_contents_utf8 length] == 0) {
      fprintf(stderr, "ERROR: failed to get the utf8 encoding of the strings "
              "file for language: %s\n", cur_lang);
      exit(1);
    }

    // Make sure the lproj we write to exists
    NSString *output_path =
        [[NSString stringWithUTF8String:output_dir]
         stringByAppendingPathComponent:
          [NSString stringWithFormat:@"%s.lproj", cur_lang]];
    NSError* error = nil;
    if (![fm fileExistsAtPath:output_path] &&
        ![fm createDirectoryAtPath:output_path
        withIntermediateDirectories:YES
                        attributes:nil
                             error:&error]) {
      fprintf(stderr, "ERROR: '%s' didn't exist or we failed to create it\n",
              [output_path UTF8String]);
      exit(1);
    }

    // Write out the file
    output_path =
        [output_path stringByAppendingPathComponent:@"InfoPlist.strings"];
    if (![strings_file_contents_utf8 writeToFile:output_path
                                      atomically:YES]) {
      fprintf(stderr, "ERROR: Failed to write out '%s'\n",
              [output_path UTF8String]);
      exit(1);
    }
  }
  return 0;
}
