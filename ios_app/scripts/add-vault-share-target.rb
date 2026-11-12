#!/usr/bin/env ruby
# Register the JarvisVaultShare share extension ("Save to Vault") as an Xcode target and
# embed it in the app. Idempotent; scripts/sync-project.rb runs it on every build, the same
# way it runs add-widget-target.rb.
#
# Sources: every *.swift under JarvisVaultShare/, plus the one file it shares with the app
# (Copilot/Vault/VaultShareKeychain.swift — the Keychain hand-off of server + folder names).
#
#   ruby scripts/add-vault-share-target.rb
require 'xcodeproj'
require 'fileutils'

ROOT = File.expand_path('..', __dir__)
PROJECT = File.join(ROOT, 'JarvisCopilot.xcodeproj')
APP = 'JarvisCopilot'
EXT = 'JarvisVaultShare'
BUNDLE = 'com.jarviscopilot.jarviscopilotMobileAndIOS.VaultShare'
TEAM = 'VY5CNF8734'
DEPLOYMENT = '18.0'
SHARED = ['JarvisCopilot/Copilot/Vault/VaultShareKeychain.swift']
LOCK = File.join(ROOT, 'build', '.sync-project.lock')

def ext_settings
  {
    'PRODUCT_NAME' => '$(TARGET_NAME)',
    'PRODUCT_BUNDLE_IDENTIFIER' => BUNDLE,
    'DEVELOPMENT_TEAM' => TEAM,
    'CODE_SIGN_STYLE' => 'Automatic',
    'CODE_SIGN_ENTITLEMENTS' => 'JarvisVaultShare/JarvisVaultShare.entitlements',
    'IPHONEOS_DEPLOYMENT_TARGET' => DEPLOYMENT,
    'SWIFT_VERSION' => '5.0',
    'TARGETED_DEVICE_FAMILY' => '1,2',
    'SUPPORTED_PLATFORMS' => 'iphoneos iphonesimulator',
    'SDKROOT' => 'iphoneos',
    'SKIP_INSTALL' => 'YES',
    'CURRENT_PROJECT_VERSION' => '1',
    'MARKETING_VERSION' => '1.0',
    'APPLICATION_EXTENSION_API_ONLY' => 'YES',
    'GENERATE_INFOPLIST_FILE' => 'NO',
    'INFOPLIST_FILE' => 'JarvisVaultShare/Info.plist',
  }
end

FileUtils.mkdir_p(File.dirname(LOCK))
acquired = false
60.times do
  begin
    Dir.mkdir(LOCK); acquired = true; break
  rescue Errno::EEXIST
    if Time.now - File.mtime(LOCK) > 60 then Dir.rmdir(LOCK) rescue nil end
    sleep 1
  end
end
abort 'add-vault-share-target: could not acquire lock' unless acquired

begin
  project = Xcodeproj::Project.open(PROJECT)
  app = project.targets.find { |t| t.name == APP } or abort 'app target missing'
  ext = project.targets.find { |t| t.name == EXT }
  created = false

  unless ext
    ext = project.new(Xcodeproj::Project::Object::PBXNativeTarget)
    project.targets << ext
    ext.name = EXT
    ext.product_name = EXT
    ext.product_type = 'com.apple.product-type.app-extension'
    ext.build_configuration_list = Xcodeproj::Project::ProjectHelper
      .configuration_list(project, :ios, DEPLOYMENT, ext, :framework)
    product = project.products_group.new_reference("#{EXT}.appex", :built_products)
    product.explicit_file_type = 'wrapper.app-extension'
    product.include_in_index = '0'
    product.set_source_tree('BUILT_PRODUCTS_DIR')
    ext.product_reference = product
    ext.source_build_phase
    ext.frameworks_build_phase
    ext.resources_build_phase
    created = true
  end

  ext.build_configurations.each { |c| c.build_settings.merge!(ext_settings) }

  group = project.main_group.find_subpath(EXT, true)
  group.set_source_tree('SOURCE_ROOT')
  ['JarvisVaultShare/JarvisVaultShare.entitlements', 'JarvisVaultShare/Info.plist'].each do |path|
    group.new_reference(path) unless group.files.any? { |f| f.path == path }
  end

  sources = Dir.glob(File.join(ROOT, EXT, '**', '*.swift')).map { |p| p.sub("#{ROOT}/", '') }
  sources.each do |path|
    ref = group.files.find { |f| f.path == path } || group.new_reference(path)
    ext.source_build_phase.add_file_reference(ref, true) unless ext.source_build_phase.files.any? { |bf| bf.file_ref == ref }
  end
  # The shared file is already referenced by the app (sync-project.rb); reuse that reference.
  SHARED.each do |path|
    ref = project.files.find { |f| f.real_path.to_s == File.join(ROOT, path) }
    next unless ref
    ext.source_build_phase.add_file_reference(ref, true) unless ext.source_build_phase.files.any? { |bf| bf.file_ref == ref }
  end

  embed = app.build_phases.find do |phase|
    phase.respond_to?(:symbol_dst_subfolder_spec) && phase.symbol_dst_subfolder_spec == :plug_ins
  end
  unless embed
    embed = project.new(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase)
    embed.name = 'Embed Foundation Extensions'
    embed.symbol_dst_subfolder_spec = :plug_ins
    app.build_phases << embed
  end
  unless embed.files.any? { |bf| bf.file_ref == ext.product_reference }
    file = embed.add_file_reference(ext.product_reference)
    file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
  end
  app.add_dependency(ext) unless app.dependencies.any? { |d| d.target == ext }

  project.save
  puts "add-vault-share-target: #{created ? 'created' : 'ok'}"
ensure
  Dir.rmdir(LOCK) rescue nil
end
