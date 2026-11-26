Pod::Spec.new do |s|
  s.name             = 'nabrila'
  s.version          = '0.1.0'
  s.summary          = 'Instant bug reports with technical context for Flutter apps.'
  s.description      = 'Native frame encoding for the Nabrila replay. Downloaded by pub (not CocoaPods).'
  s.homepage         = 'https://nabrila.com'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'Nabrila' => 'hello@nabrila.com' }
  s.source           = { :http => 'https://nabrila.com' }
  s.source_files     = 'nabrila/Sources/nabrila/**/*.swift'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
