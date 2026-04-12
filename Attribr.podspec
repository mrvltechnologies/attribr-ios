Pod::Spec.new do |s|
  s.name             = 'Attribr'
  s.version          = '1.0.0'
  s.summary          = 'Install attribution and 30-day retention SDK by MRVL Technologies.'
  s.homepage         = 'https://mrvltechnologies.com'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'MRVL Technologies' => 'support@mrvltechnologies.com' }
  s.source           = { :path => '.' }
  s.swift_versions   = ['5.5', '6.0']
  s.ios.deployment_target = '15.0'

  s.source_files = 'Sources/Attribr/**/*.swift'
  s.resource_bundles = {
    'Attribr_Privacy' => ['Sources/Attribr/PrivacyInfo.xcprivacy']
  }

  s.frameworks = 'Foundation', 'CryptoKit'
end
