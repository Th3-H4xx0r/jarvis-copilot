#!/usr/bin/env ruby
# Registers the JarvisWidget WidgetKit extension as an Xcode target and embeds
# it in Runner, so the Lock Screen / Home Screen widget actually builds and
# appears in iOS's widget gallery. Idempotent: re-running is a no-op.
#
# Run with CocoaPods' bundled xcodeproj gem:
#   GEM_HOME=/opt/homebrew/Cellar/cocoapods/<ver>/libexec \
#     /opt/homebrew/opt/ruby/bin/ruby ios/add_widget_target.rb
require 'xcodeproj'

PROJECT = File.join(__dir__, 'Runner.xcodeproj')
WIDGET  = 'JarvisWidget'
BUNDLE  = 'com.jarviscopilot.jarviscopilotMobileAndIOS'
TEAM    = '62JUP2GJHV'

proj = Xcodeproj::Project.open(PROJECT)

if proj.targets.any? { |t| t.name == WIDGET }
  puts "#{WIDGET} target already exists — nothing to do."
  exit 0
end

runner = proj.targets.find { |t| t.name == 'Runner' } or abort 'Runner target not found'

# 1. Create the app-extension target.
widget = proj.new(Xcodeproj::Project::Object::PBXNativeTarget)
proj.targets << widget
widget.name = WIDGET
widget.product_name = WIDGET
widget.product_type = 'com.apple.product-type.app-extension'
widget.build_configuration_list =
  Xcodeproj::Project::ProjectHelper.configuration_list(proj, :ios, '16.0', widget, :framework)

# product reference (.appex)
product_ref = proj.products_group.new_reference("#{WIDGET}.appex", :built_products)
product_ref.explicit_file_type = 'wrapper.app-extension'
product_ref.include_in_index = '0'
product_ref.set_source_tree('BUILT_PRODUCTS_DIR')
widget.product_reference = product_ref

# 2. Build settings on each config.
widget.build_configurations.each do |c|
  c.build_settings.merge!(
    'PRODUCT_BUNDLE_IDENTIFIER' => "#{BUNDLE}.JarvisWidget",
    'PRODUCT_NAME'              => '$(TARGET_NAME)',
    'DEVELOPMENT_TEAM'          => TEAM,
    'INFOPLIST_FILE'            => 'JarvisWidget/Info.plist',
    'IPHONEOS_DEPLOYMENT_TARGET'=> '16.0',
    'SWIFT_VERSION'             => '5.0',
    'TARGETED_DEVICE_FAMILY'    => '1,2',
    'CODE_SIGN_STYLE'           => 'Automatic',
    'SKIP_INSTALL'              => 'YES',
    'GENERATE_INFOPLIST_FILE'   => 'NO',
    'CURRENT_PROJECT_VERSION'   => '1',
    'MARKETING_VERSION'         => '1.0',
  )
end

# 3. Source group + file, sources build phase.
group = proj.main_group.find_subpath(WIDGET, true)
group.set_source_tree('SOURCE_ROOT')
swift = group.new_reference("#{WIDGET}/#{WIDGET}.swift")
proj.main_group.find_subpath(WIDGET, true).new_reference("#{WIDGET}/Info.plist")
src_phase = widget.new_shell_script_build_phase rescue nil # ensure phases exist
widget.source_build_phase.add_file_reference(swift)
widget.frameworks_build_phase # ensure created

# Link SwiftUI + WidgetKit
%w[SwiftUI WidgetKit].each do |fw|
  ref = proj.frameworks_group.new_reference("System/Library/Frameworks/#{fw}.framework")
  ref.set_source_tree('SDKROOT')
  widget.frameworks_build_phase.add_file_reference(ref)
end

# 4. Embed the .appex into Runner (Embed App Extensions phase).
embed = runner.build_phases.find { |p|
  p.respond_to?(:symbol_dst_subfolder_spec) && p.symbol_dst_subfolder_spec == :plug_ins
}
embed ||= begin
  ph = proj.new(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase)
  ph.name = 'Embed Foundation Extensions'
  ph.symbol_dst_subfolder_spec = :plug_ins
  runner.build_phases << ph
  ph
end
build_file = embed.add_file_reference(product_ref)
build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

# 5. Runner depends on the widget so it builds first.
runner.add_dependency(widget)

proj.save
puts "Registered #{WIDGET} target and embedded it in Runner."
