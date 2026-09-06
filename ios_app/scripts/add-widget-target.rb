#!/usr/bin/env ruby
# Register the JarvisWidget WidgetKit extension as an Xcode target and embed it
# in the app, so the Lock Screen / Home Screen widget, the Control Center control
# and the Live Activity (Dynamic Island) actually build and appear.
#
# Idempotent: re-running is a no-op, and scripts/sync-project.rb calls it on every
# build so a fresh checkout needs no manual Xcode step.  Mirrors sync-project.rb's
# style — same mkdir lock, same `PRODUCT_NAME = $(TARGET_NAME)`.
#
#   ruby scripts/add-widget-target.rb
require 'xcodeproj'
require 'fileutils'

ROOT = File.expand_path('..', __dir__)
PROJECT = File.join(ROOT, 'JarvisCopilot.xcodeproj')
APP = 'JarvisCopilot'
WIDGET = 'JarvisWidget'
BUNDLE = 'com.jarviscopilot.jarviscopilotMobileAndIOS.JarvisWidget'
TEAM = 'VY5CNF8734'
DEPLOYMENT = '17.0'
LOCK = File.join(ROOT, 'build', '.sync-project.lock')

# Build settings the widget needs, applied on every run so a hand-edit or a
# regenerated config can't leave the target half-configured.
def widget_settings
  {
    'PRODUCT_NAME' => '$(TARGET_NAME)',
    'PRODUCT_BUNDLE_IDENTIFIER' => BUNDLE,
    'DEVELOPMENT_TEAM' => TEAM,
    'CODE_SIGN_STYLE' => 'Automatic',
    'CODE_SIGN_ENTITLEMENTS' => 'JarvisWidget/JarvisWidget.entitlements',
    'IPHONEOS_DEPLOYMENT_TARGET' => DEPLOYMENT,
    'SWIFT_VERSION' => '5.0',
    'TARGETED_DEVICE_FAMILY' => '1,2',
    # A WidgetKit extension is iOS-only; the app target also lists macosx at the
    # project level, and inheriting that here would fail the build outright.
    'SUPPORTED_PLATFORMS' => 'iphoneos iphonesimulator',
    'SDKROOT' => 'iphoneos',
    'SKIP_INSTALL' => 'YES',
    'CURRENT_PROJECT_VERSION' => '1',
    'MARKETING_VERSION' => '1.0',
    'SWIFT_EMIT_LOC_STRINGS' => 'YES',
    # A REAL, checked-in Info.plist — not a generated one. Xcode 26 does not emit
    # an NSExtension dictionary from INFOPLIST_KEY_NSExtensionPointIdentifier for
    # this product type, and without one the simulator refuses to install the HOST
    # app ("extensionDictionary must be set in placeholder attributes"), which
    # breaks every agent's scripts/test.sh, not just the widget.
    'GENERATE_INFOPLIST_FILE' => 'NO',
    'INFOPLIST_FILE' => 'JarvisWidget/Info.plist',
  }
end

FileUtils.mkdir_p(File.dirname(LOCK))
acquired = false
60.times do
  begin
    Dir.mkdir(LOCK); acquired = true; break
  rescue Errno::EEXIST
    # Stale lock (a crashed run) — reclaim after 60 s.
    if Time.now - File.mtime(LOCK) > 60 then Dir.rmdir(LOCK) rescue nil end
    sleep 1
  end
end
abort 'add-widget-target: could not acquire lock' unless acquired

begin
  project = Xcodeproj::Project.open(PROJECT)
  app = project.targets.find { |t| t.name == APP } or abort 'app target missing'
  widget = project.targets.find { |t| t.name == WIDGET }
  created = false

  unless widget
    widget = project.new(Xcodeproj::Project::Object::PBXNativeTarget)
    project.targets << widget
    widget.name = WIDGET
    widget.product_name = WIDGET
    widget.product_type = 'com.apple.product-type.app-extension'
    widget.build_configuration_list = Xcodeproj::Project::ProjectHelper
      .configuration_list(project, :ios, DEPLOYMENT, widget, :framework)

    product = project.products_group.new_reference("#{WIDGET}.appex", :built_products)
    product.explicit_file_type = 'wrapper.app-extension'
    product.include_in_index = '0'
    product.set_source_tree('BUILT_PRODUCTS_DIR')
    widget.product_reference = product

    widget.source_build_phase   # force the phases into existence
    widget.frameworks_build_phase
    widget.resources_build_phase
    created = true
    warn "add-widget-target: created target #{WIDGET}"
  end

  widget.build_configurations.each do |c|
    c.build_settings.merge!(widget_settings)
    # Left over from an earlier attempt at a generated Info.plist. These are
    # silently ignored for this product type, so drop them rather than leave
    # settings that read as if they were doing the work.
    %w[INFOPLIST_KEY_NSExtensionPointIdentifier
       INFOPLIST_KEY_CFBundleDisplayName
       INFOPLIST_KEY_NSHumanReadableCopyright].each { |k| c.build_settings.delete(k) }
  end

  # The entitlements file lives next to the sources and is referenced (not
  # compiled) so it shows up in Xcode's navigator.
  group = project.main_group.find_subpath(WIDGET, true)
  group.set_source_tree('SOURCE_ROOT')
  ['JarvisWidget/JarvisWidget.entitlements', 'JarvisWidget/Info.plist'].each do |path|
    group.new_reference(path) unless group.files.any? { |f| f.path == path }
  end

  # System frameworks. Swift auto-links these, but naming them keeps the target
  # honest if a future file drops the import.
  %w[WidgetKit SwiftUI ActivityKit].each do |name|
    path = "System/Library/Frameworks/#{name}.framework"
    already = widget.frameworks_build_phase.files.any? { |bf| bf.file_ref&.path == path }
    next if already
    ref = project.frameworks_group.new_reference(path)
    ref.set_source_tree('SDKROOT')
    widget.frameworks_build_phase.add_file_reference(ref)
  end

  # Embed the .appex in the app, and make the app depend on it so it builds first.
  embed = app.build_phases.find do |phase|
    phase.respond_to?(:symbol_dst_subfolder_spec) && phase.symbol_dst_subfolder_spec == :plug_ins
  end
  unless embed
    embed = project.new(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase)
    embed.name = 'Embed Foundation Extensions'
    embed.symbol_dst_subfolder_spec = :plug_ins
    app.build_phases << embed
  end
  unless embed.files.any? { |bf| bf.file_ref == widget.product_reference }
    file = embed.add_file_reference(widget.product_reference)
    file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
  end
  app.add_dependency(widget) unless app.dependencies.any? { |d| d.target == widget }

  project.save
  puts "add-widget-target: #{created ? 'created' : 'ok'} (#{WIDGET} embedded in #{APP})"
ensure
  Dir.rmdir(LOCK) rescue nil
end
