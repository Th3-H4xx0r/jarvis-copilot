#!/usr/bin/env ruby
# Sync the Xcode project with the file system.
#
# The JarvisCopilot project has no file-system-synced groups, so every new Swift
# file has to be registered in project.pbxproj by hand. This script does that
# idempotently:
#   * every *.swift under JarvisCopilot/      -> app target (Sources phase)
#   * every *.swift under JarvisCopilotTests/ -> XCTest unit-test target
#     (created on first run, host application = the app)
#   * every *.swift under JarvisWidget/         -> the WidgetKit extension target
#     (created by scripts/add-widget-target.rb, which this script runs first)
#   * every *.swift under JarvisCopilot/Copilot/Shared/ -> BOTH the app and the
#     widget, because the Live Activity's attributes and the App Group ids have to
#     be one declaration compiled twice, never two that can drift
#   * a shared scheme "JarvisCopilot" with a Test action covering the test target
#
# Safe to run repeatedly and from several agents: a mkdir-based lock serialises
# concurrent runs.  Usage:  ruby scripts/sync-project.rb
require 'xcodeproj'
require 'fileutils'

ROOT = File.expand_path('..', __dir__)
PROJECT = File.join(ROOT, 'JarvisCopilot.xcodeproj')
APP_DIR = 'JarvisCopilot'
TEST_DIR = 'JarvisCopilotTests'
TEST_TARGET = 'JarvisCopilotTests'
WIDGET_DIR = 'JarvisWidget'
WIDGET_TARGET = 'JarvisWidget'
SHARED_DIR = File.join(APP_DIR, 'Copilot', 'Shared')
LOCK = File.join(ROOT, 'build', '.sync-project.lock')

# Create/refresh the widget extension target BEFORE taking the lock — that script
# takes the same one.
unless system(RbConfig.ruby, File.join(__dir__, 'add-widget-target.rb'), out: File::NULL)
  warn 'sync-project: add-widget-target.rb failed; continuing without the widget'
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
abort 'sync-project: could not acquire lock' unless acquired

begin
  project = Xcodeproj::Project.open(PROJECT)
  app = project.targets.find { |t| t.name == 'JarvisCopilot' } or abort 'app target missing'

  def ensure_group(project, name)
    project.main_group[name] || project.main_group.new_group(name, name)
  end

  # Register every swift file under `dir` (recursive) with `target`, mirroring
  # sub-directories as groups. Returns the number of files added.
  def sync_sources(project, target, dir, group)
    added = 0
    existing = target.source_build_phase.files.map { |bf| bf.file_ref&.real_path.to_s }
    Dir.glob(File.join(project.project_dir, dir, '**', '*.swift')).sort.each do |abs|
      next if existing.include?(abs)
      rel = Pathname.new(abs).relative_path_from(Pathname.new(File.join(project.project_dir, dir)))
      g = group
      rel.dirname.each_filename { |part| g = g[part] || g.new_group(part, part) }
      ref = g.files.find { |f| f.real_path.to_s == abs } || g.new_file(abs)
      target.add_file_references([ref])
      added += 1
    end
    # Drop references to files that no longer exist on disk.
    target.source_build_phase.files.dup.each do |bf|
      ref = bf.file_ref
      next if ref.nil?
      path = ref.real_path.to_s
      if path.end_with?('.swift') && path.start_with?(File.join(project.project_dir, dir)) && !File.exist?(path)
        target.source_build_phase.remove_build_file(bf)
        ref.remove_from_project
        warn "sync-project: removed stale #{path}"
      end
    end
    added
  end

  # Add the *.swift files under `dir` to `target` REUSING the existing file
  # references (they already belong to another target's group), and drop the ones
  # whose file has since been deleted. Used for Copilot/Shared, which is compiled
  # into the app and the widget both.
  def share_sources(project, target, dir)
    added = 0
    root = File.join(project.project_dir, dir)
    existing = target.source_build_phase.files.map { |bf| bf.file_ref&.real_path.to_s }
    Dir.glob(File.join(root, '**', '*.swift')).sort.each do |abs|
      next if existing.include?(abs)
      ref = project.files.find { |f| f.real_path.to_s == abs }
      next if ref.nil?   # the owning target's sync adds it first; next run picks it up
      target.add_file_references([ref])
      added += 1
    end
    target.source_build_phase.files.dup.each do |bf|
      ref = bf.file_ref
      next if ref.nil?
      path = ref.real_path.to_s
      if path.start_with?(root) && !File.exist?(path)
        target.source_build_phase.remove_build_file(bf)
      end
    end
    added
  end

  app_group = project.main_group[APP_DIR] or abort 'JarvisCopilot group missing'
  added_app = sync_sources(project, app, APP_DIR, app_group)

  test = project.targets.find { |t| t.name == TEST_TARGET }
  unless test
    test = project.new_target(:unit_test_bundle, TEST_TARGET, :ios, '17.0', nil, :swift)
    test.add_dependency(app)
    test.build_configurations.each do |cfg|
      cfg.build_settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/JarvisCopilot.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/JarvisCopilot'
      cfg.build_settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
      cfg.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.jarviscopilot.jarviscopilotMobileAndIOS.Tests'
      cfg.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
      cfg.build_settings['SWIFT_VERSION'] = '5.0'
      cfg.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
      cfg.build_settings['SUPPORTED_PLATFORMS'] = 'iphoneos iphonesimulator'
      cfg.build_settings['TARGETED_DEVICE_FAMILY'] = '1,2'
      cfg.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
      cfg.build_settings['DEVELOPMENT_TEAM'] = 'VY5CNF8734'
      cfg.build_settings['SWIFT_EMIT_LOC_STRINGS'] = 'NO'
      cfg.build_settings.delete('INFOPLIST_FILE')
    end
    warn "sync-project: created target #{TEST_TARGET}"
  end
  test.build_configurations.each { |cfg| cfg.build_settings["PRODUCT_NAME"] = "$(TARGET_NAME)" }
  FileUtils.mkdir_p(File.join(ROOT, TEST_DIR))
  test_group = ensure_group(project, TEST_DIR)
  added_test = sync_sources(project, test, TEST_DIR, test_group)

  # The WidgetKit extension: its own sources, plus Copilot/Shared compiled a
  # second time (JarvisActivityAttributes, JarvisShared, OpenJarvisVoiceIntent).
  added_widget = 0
  widget = project.targets.find { |t| t.name == WIDGET_TARGET }
  if widget && Dir.exist?(File.join(ROOT, WIDGET_DIR))
    widget_group = ensure_group(project, WIDGET_DIR)
    added_widget = sync_sources(project, widget, WIDGET_DIR, widget_group)
    added_widget += share_sources(project, widget, SHARED_DIR)
  end

  # The test target needs the app's @testable interface.
  app.build_configurations.each do |cfg|
    cfg.build_settings['ENABLE_TESTABILITY'] = 'YES' if cfg.name == 'Debug'
  end

  project.save

  # Shared scheme with build + test actions.
  scheme_path = Xcodeproj::XCScheme.shared_data_dir(PROJECT) + 'JarvisCopilot.xcscheme'
  scheme = File.exist?(scheme_path) ? Xcodeproj::XCScheme.new(scheme_path) : Xcodeproj::XCScheme.new
  if scheme.test_action.testables.none? { |t| t.buildable_references.any? { |r| r.target_name == TEST_TARGET } }
    scheme = Xcodeproj::XCScheme.new
    scheme.configure_with_targets(app, test, launch_target: true)
    scheme.save_as(PROJECT, 'JarvisCopilot', true)
    warn 'sync-project: wrote shared scheme JarvisCopilot (build + test)'
  end

  puts "sync-project: app +#{added_app} test +#{added_test} widget +#{added_widget} (ok)"
ensure
  Dir.rmdir(LOCK) rescue nil
end
