// iOS-only logging shim.
//
// Keep Objective-C out of common C code: common/log.c calls ardop_ios_nslog()
// on iOS targets to emit logs via NSLog.

#import <Foundation/Foundation.h>

void ardop_ios_nslog(const char *line)
{
	if (!line)
		return;
	NSLog(@"%s", line);
}

