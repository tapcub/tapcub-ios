Pod::Spec.new do |s|
  s.name             = 'TapCub'
  s.version          = '0.1.0'
  s.summary          = 'TapCub analytics SDK for iOS: events, screens, sessions, consent, crashes.'
  s.homepage         = 'https://tapcub.com'
  s.license          = { :type => 'MIT' }
  s.author           = { 'TapCub' => 'sdk@tapcub.io' }
  s.source           = { :git => 'https://github.com/tapcub/tapcub-ios.git', :tag => s.version.to_s }

  s.ios.deployment_target  = '13.0'
  s.tvos.deployment_target = '13.0'
  s.swift_version    = '5.9'

  # Core, adapters and the C signal handler build into one module here; SwiftPM splits them.
  s.source_files         = 'Sources/TapCubCore/**/*.swift', 'Sources/TapCub/**/*.swift', 'Sources/TapCubCrashC/**/*.{h,c}'
  s.public_header_files  = 'Sources/TapCubCrashC/include/*.h'
  s.resource_bundles     = { 'TapCub_Privacy' => ['Sources/TapCub/PrivacyInfo.xcprivacy'] }
  s.frameworks           = 'Foundation', 'Network', 'CryptoKit'
  s.ios.weak_frameworks  = 'MetricKit'
  s.pod_target_xcconfig  = { 'SWIFT_OPTIMIZATION_LEVEL[config=Release]' => '-Osize' }
end
