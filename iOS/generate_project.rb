require 'xcodeproj'
require 'fileutils'

root = File.expand_path(__dir__)
project = Xcodeproj::Project.new(File.join(root, 'PokerCoach.xcodeproj'))
project.root_object.attributes['LastUpgradeCheck'] = '2660'
project.root_object.development_region = 'zh-Hans'
project.root_object.known_regions = ['en', 'zh-Hans', 'Base']
team = ENV.fetch('POKER_DEVELOPMENT_TEAM', '')
bundle_base = ENV.fetch('POKER_BUNDLE_ID', 'org.research.pokercoach')
project.build_configurations.each do |c|
  c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
  c.build_settings['SWIFT_VERSION'] = '5.0'
  c.build_settings['CLANG_ENABLE_MODULES'] = 'YES'
end

app = project.new_target(:application, 'PokerCoach', :ios, '17.0')
ext = project.new_target(:app_extension, 'PokerCoachBroadcast', :ios, '17.0')
tests = project.new_target(:ui_test_bundle, 'PokerCoachUITests', :ios, '17.0')
[[app, bundle_base], [ext, bundle_base + '.broadcast'], [tests, bundle_base + '.uitests']].each do |target, bundle|
  target.build_configurations.each do |c|
    c.build_settings.merge!({
      'PRODUCT_BUNDLE_IDENTIFIER' => bundle, 'DEVELOPMENT_TEAM' => team,
      'CODE_SIGN_STYLE' => 'Automatic', 'CURRENT_PROJECT_VERSION' => '15',
      'MARKETING_VERSION' => '0.1.14', 'TARGETED_DEVICE_FAMILY' => '1',
      'SWIFT_VERSION' => '5.0', 'ENABLE_USER_SCRIPT_SANDBOXING' => 'YES',
      'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/Frameworks'],
      'GENERATE_INFOPLIST_FILE' => 'NO'
    })
  end
end

package = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
package.relative_path = '..'
project.root_object.package_references << package
%w[PokerCoachCore PokerCoachCapture PokerCoachUI].each do |name|
  product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  product.package = package; product.product_name = name
  app.package_product_dependencies << product
  build = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build.product_ref = product; app.frameworks_build_phase.files << build
end

app_group = project.main_group.new_group('PokerCoachApp', 'PokerCoachApp')
Dir[File.join(root, 'PokerCoachApp', '*.swift')].sort.each { |p| app.add_file_references([app_group.new_file(File.basename(p))]) }
assets = app_group.new_file('Assets.xcassets'); app.resources_build_phase.add_file_reference(assets)
fixture = project.main_group.new_file('../fixtures/six-player-flop.json')
app.resources_build_phase.add_file_reference(fixture)
app.build_configurations.each do |c|
  c.build_settings['INFOPLIST_FILE'] = 'PokerCoachApp/Info.plist'
  c.build_settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
end

ext_group = project.main_group.new_group('PokerCoachBroadcast', 'PokerCoachBroadcast')
ext.add_file_references([ext_group.new_file('SampleHandler.swift')])
shared = project.main_group.new_group('Shared transport')
%w[FrameSender.swift FrameProtocol.swift].each do |file|
  ext.add_file_references([shared.new_file('../Sources/PokerCoachCapture/' + file)])
end
ext.build_configurations.each do |c|
  c.build_settings['INFOPLIST_FILE'] = 'PokerCoachBroadcast/Info.plist'
  c.build_settings['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
  c.build_settings['SKIP_INSTALL'] = 'YES'
  c.build_settings['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks']
end
app.add_dependency(ext)
embed = app.new_copy_files_build_phase('Embed App Extensions')
embed.dst_subfolder_spec = '13'
embed.add_file_reference(ext.product_reference).settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

test_group = project.main_group.new_group('PokerCoachUITests', 'PokerCoachUITests')
tests.add_file_references([test_group.new_file('SmokeTests.swift')])
tests.add_dependency(app)
tests.build_configurations.each do |c|
  c.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  c.build_settings['TEST_TARGET_NAME'] = 'PokerCoach'
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(tests)
scheme.set_launch_target(app)
scheme.test_action.build_configuration = 'Debug'
scheme.save_as(project.path, 'PokerCoach', true)
puts project.path
