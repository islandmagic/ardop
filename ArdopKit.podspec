Pod::Spec.new do |s|
  s.name             = 'ArdopKit'
  s.version          = '0.1.1'
  s.summary          = 'ARDOP modem embedded for iOS (ardopcf as XCFramework).'
  s.description      = <<-DESC
  ArdopKit wraps the ardopcf ARDOP modem for use inside an iOS application: AVAudioEngine I/O,
  embedded host queues, and an Objective-C API. The desktop TCP host interface and rig control
  (serial/CM108/hamlib) are not part of this iOS build.
  DESC

  s.homepage         = 'https://github.com/pflarue/ardop'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'ARDOP Contributors' => 'https://github.com/pflarue/ardop' }

  # Local / path-based installs (recommended while iterating).
  s.source           = { :path => '.' }

  s.platform         = :ios

  # Prebuilt static library + ObjC headers (same artifact `make xcframework-ios` produces).
  # Do not set `source_files` to all of `src/**`: that pulls Windows/Linux sources, skips
  # Makefile -I/-D flags, omits txt2c-generated webgui sources, and duplicates this binary.
  # While iterating locally, we want code changes to reliably rebuild the XCFramework.
  # CocoaPods only runs prepare_command during `pod install`, so make it always rebuild.
  s.prepare_command    = <<-SH
    set -e
    make xcframework-ios
  SH

  s.vendored_frameworks = 'build/ArdopKit.xcframework'

  s.public_header_files = [
    'build/ArdopKit.xcframework/ios-arm64/Headers/**/*.h',
    'build/ArdopKit.xcframework/ios-arm64_x86_64-simulator/Headers/**/*.h',
  ]

  s.frameworks         = 'AVFoundation', 'Foundation', 'CoreFoundation'
  s.libraries          = 'c++', 'c++abi'

  s.pod_target_xcconfig = {
    'OTHER_LDFLAGS' => '$(inherited) -lc++ -lc++abi',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
  }

  s.user_target_xcconfig = {
    'OTHER_LDFLAGS' => '$(inherited) -lc++ -lc++abi',
  }

  s.requires_arc = true
end
