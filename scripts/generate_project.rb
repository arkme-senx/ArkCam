require 'xcodeproj'

root = File.expand_path('..', __dir__)
project = Xcodeproj::Project.new(File.join(root, 'Cam.xcodeproj'))
project.root_object.development_region = 'zh-Hans'
project.root_object.known_regions = ['zh-Hans', 'zh-Hant', 'en', 'ja', 'ko', 'es', 'fr', 'de', 'it', 'pt-BR', 'ru', 'ar', 'hi', 'id', 'th', 'vi', 'Base']

app = project.new_target(:application, 'Cam', :ios, '17.0')
unit = project.new_target(:unit_test_bundle, 'CamTests', :ios, '17.0')
ui = project.new_target(:ui_test_bundle, 'CamUITests', :ios, '17.0')

[[app, 'Cam'], [unit, 'CamTests'], [ui, 'CamUITests']].each do |target, folder|
  group = project.main_group.new_group(folder, folder)
  Dir.glob(File.join(root, folder, '*.swift')).sort.each do |path|
    ref = group.new_file(File.basename(path))
    target.source_build_phase.add_file_reference(ref)
  end
  if target == app
    asset = group.new_file('Assets.xcassets')
    target.resources_build_phase.add_file_reference(asset)
  end
  target.build_configurations.each do |config|
    config.build_settings.merge!({
      'PRODUCT_BUNDLE_IDENTIFIER' => "com.tison.dualcam#{target == app ? '' : ".#{folder}"}",
      'SWIFT_VERSION' => '5.0',
      'TARGETED_DEVICE_FAMILY' => '1,2',
      'IPHONEOS_DEPLOYMENT_TARGET' => '17.0',
      'CODE_SIGN_STYLE' => 'Automatic',
      'DEVELOPMENT_TEAM' => 'T6NSNA8LDZ',
      'MARKETING_VERSION' => '0.1.0',
      'CURRENT_PROJECT_VERSION' => '56',
      'GENERATE_INFOPLIST_FILE' => 'YES',
      'SWIFT_EMIT_LOC_STRINGS' => 'YES',
      'ENABLE_USER_SCRIPT_SANDBOXING' => 'YES'
    })
    config.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = [config.name == 'Debug' ? 'DEBUG' : nil, target == app ? 'CAM_MAIN_APP' : nil].compact.join(' ')
    if target == app
      config.build_settings['GENERATE_INFOPLIST_FILE'] = 'NO'
      config.build_settings['INFOPLIST_FILE'] = 'Cam/Info.plist'
      config.build_settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
      config.build_settings['OTHER_LDFLAGS'] = '$(inherited) -weak_framework LockedCameraCapture'
    elsif target == unit
      config.build_settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/Cam.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Cam'
      config.build_settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
    else
      config.build_settings['TEST_TARGET_NAME'] = 'Cam'
    end
  end
end
shared = project.main_group.new_group('Shared', 'Shared')
intent = shared.new_file('CamCaptureIntent.swift')
app.source_build_phase.add_file_reference(intent)
defaults = shared.new_file('CameraDefaults.swift')
app.source_build_phase.add_file_reference(defaults)
localization = shared.new_file('Localization.swift')
app.source_build_phase.add_file_reference(localization)
resources = shared.new_group('Resources', 'Resources')
logo = resources.new_file('ArkCamLogo.png')
app.resources_build_phase.add_file_reference(logo)
localized_resources = ['Localizable.strings', 'InfoPlist.strings'].map do |filename|
  variant = resources.new_variant_group(filename)
  project.root_object.known_regions.reject { |language| language == 'Base' }.each do |language|
    ref = variant.new_file(language + '.lproj/' + filename)
    ref.name = language
  end
  app.resources_build_phase.add_file_reference(variant)
  variant
end

['CamControls', 'CamCapture'].each do |name|
  capture = name == 'CamCapture'
  extension = project.new_target(:app_extension, name, :ios, '18.0')
  extension.product_type = 'com.apple.product-type.extensionkit-extension' if capture
  group = project.main_group.new_group(name, name)
  Dir.glob(File.join(root, name, '*.swift')).sort.each do |path|
    extension.source_build_phase.add_file_reference(group.new_file(File.basename(path)))
  end
  extension.source_build_phase.add_file_reference(intent)
  extension.source_build_phase.add_file_reference(defaults)
  extension.source_build_phase.add_file_reference(localization)
  localized_resources.each { |ref| extension.resources_build_phase.add_file_reference(ref) }
  if capture
    extension.resources_build_phase.add_file_reference(logo)
    excluded = ['CamApp.swift', 'DebugFixtures.swift', 'LockedCaptureImport.swift']
    project.main_group['Cam'].files.each do |ref|
      next unless ref.path.end_with?('.swift') && !excluded.include?(ref.path)
      extension.source_build_phase.add_file_reference(ref)
    end
  end
  extension.build_configurations.each do |config|
    config.build_settings.merge!({
      'PRODUCT_BUNDLE_IDENTIFIER' => "com.tison.dualcam.#{name}",
      'SWIFT_VERSION' => '5.0', 'TARGETED_DEVICE_FAMILY' => '1,2',
      'IPHONEOS_DEPLOYMENT_TARGET' => '18.0', 'CODE_SIGN_STYLE' => 'Automatic',
      'DEVELOPMENT_TEAM' => 'T6NSNA8LDZ', 'MARKETING_VERSION' => '0.1.0',
      'CURRENT_PROJECT_VERSION' => '56', 'GENERATE_INFOPLIST_FILE' => 'NO',
      'INFOPLIST_FILE' => "#{name}/Info.plist", 'SKIP_INSTALL' => 'YES',
      'APPLICATION_EXTENSION_API_ONLY' => 'YES',
      'LD_RUNPATH_SEARCH_PATHS' => '$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks',
      'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => [config.name == 'Debug' ? 'DEBUG' : nil, capture ? 'CAM_CAPTURE_EXTENSION' : 'CAM_CONTROL_EXTENSION'].compact.join(' ')
    })
  end
  app.add_dependency(extension)
  embed = app.new_copy_files_build_phase(capture ? 'Embed Capture Extension' : 'Embed Control Extension')
  embed.dst_subfolder_spec = capture ? '16' : '13'
  embed.dst_path = '$(CONTENTS_FOLDER_PATH)/Extensions' if capture
  embed.add_file_reference(extension.product_reference).settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
end
unit.add_dependency(app)
ui.add_dependency(app)
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.set_launch_target(app)
scheme.add_test_target(unit)
scheme.add_test_target(ui)
scheme.save_as(root + '/Cam.xcodeproj', 'Cam', true)
project.save
puts "Generated #{project.path}"
