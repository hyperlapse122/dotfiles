#import <Cocoa/Cocoa.h>

static NSURL *application;
static NSArray<NSString *> *schemes;

static void selectScheme(NSUInteger index) {
  if (index == schemes.count) exit(0);
  NSString *scheme = schemes[index];
  NSWorkspace *workspace = NSWorkspace.sharedWorkspace;
  NSURL *current = [workspace URLForApplicationToOpenURL:
      [NSURL URLWithString:[scheme stringByAppendingString:@"://example.com"]]];
  if (current && [current.URLByResolvingSymlinksInPath.URLByStandardizingPath
      isEqual:application.URLByResolvingSymlinksInPath.URLByStandardizingPath]) {
    selectScheme(index + 1);
    return;
  }
  [workspace setDefaultApplicationAtURL:application
                  toOpenURLsWithScheme:scheme
                     completionHandler:^(NSError *error) {
    if (error) {
      NSLog(@"Could not set %@ for %@: %@", application.path, scheme, error);
      exit(1);
    }
    selectScheme(index + 1);
  }];
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc != 2) return 2;
    application = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
    schemes = @[ @"http", @"https" ];
    // Consent runs asynchronously; never keep the login agent alive indefinitely.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{ exit(1); });
    selectScheme(0);
    dispatch_main();
  }
}
