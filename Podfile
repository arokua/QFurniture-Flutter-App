# Set the platform to at least 13.0 for modern plugin compatibility
platform :ios, '13.0'

# Standard Flutter pod setup
install! 'cocoapods', :deterministic_uuids => false

target 'Runner' do
  use_frameworks!
  use_modular_headers!

  # This is the "magic" line that pulls in everything from your pubspec.yaml
  flutter_install_all_ios_pods File.dirname(File.realpath(__FILE__))

  target 'RunnerTests' do
    inherit! :search_paths
  end
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)
    
    # Optional: Fix for common 'IPHONEOS_DEPLOYMENT_TARGET' mismatch warnings
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '13.0'
    end
  end
end
