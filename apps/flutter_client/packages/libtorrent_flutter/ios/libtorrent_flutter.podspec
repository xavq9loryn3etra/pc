Pod::Spec.new do |s|
  s.name             = 'libtorrent_flutter'
  s.version          = '1.7.0'
  s.summary          = 'Flutter plugin for libtorrent with built-in streaming server.'
  s.description      = <<-DESC
  Native libtorrent 2.0 bindings for Flutter with an integrated HTTP streaming server.
                       DESC
  s.homepage         = 'https://github.com/ayman708-UX/libtorrent_flutter'
  s.license          = { :type => 'GPL-3.0', :file => '../LICENSE' }
  s.author           = { 'ayman708-UX' => 'ayman@example.com' }
  s.source           = { :path => '.' }

  s.dependency 'Flutter'
  s.frameworks = 'SystemConfiguration', 'CoreFoundation'
  # libtorrent and the bridge are C++.
  s.libraries = 'c++'
  s.platform = :ios, '13.0'
  s.ios.deployment_target = '13.0'
  s.swift_version = '5.0'

  # On iOS we must statically link — Apple does not allow dynamic libraries
  # in App Store submissions. The XCFramework contains separate static libs
  # for device (arm64-iphoneos) and simulator (arm64+x86_64-iphonesimulator).
  xcframework_path = 'libtorrent_flutter.xcframework'
  xcframework_absolute = File.join(__dir__, xcframework_path)

  # ───────────────────────────────────────────────────────────────────────
  # Prebuilt XCFramework: not checked in (too big). Pulled on `pod install`
  # from our own GitHub Release, built by
  # .github/workflows/build-libtorrent-native.yml:
  #
  #   <native/PREBUILT_RELEASE_URL>/ios-native-lib.zip
  #
  # Set LIBTORRENT_FLUTTER_SKIP_DOWNLOAD=1 to opt out (e.g. when you've
  # dropped your own libtorrent_flutter.xcframework in here).
  # ───────────────────────────────────────────────────────────────────────
  release_base = File.read(File.join(__dir__, '..', 'native', 'PREBUILT_RELEASE_URL')).strip
  # The zip's expected SHA-256, from native/PREBUILT_SHA256 (sha256sum format,
  # one line per zip).
  require 'digest'
  zip_name = 'ios-native-lib.zip'
  hash_file = File.join(__dir__, '..', 'native', 'PREBUILT_SHA256')
  expected_hash = nil
  if File.exist?(hash_file)
    File.readlines(hash_file).each do |line|
      digest, name = line.strip.split(/\s+/, 2)
      expected_hash = digest.downcase if digest && name && name.sub(/\A\*/, '') == zip_name
    end
  end
  # Records which release (and which hash) the XCFramework came from, so
  # bumping PREBUILT_RELEASE_URL or the hash replaces a previously
  # downloaded copy.
  marker = "#{release_base} #{expected_hash}"
  source_marker = File.join(xcframework_absolute, '.source')
  up_to_date = File.exist?(source_marker) && File.read(source_marker).strip == marker

  if !up_to_date && ENV['LIBTORRENT_FLUTTER_SKIP_DOWNLOAD'] != '1'
    if expected_hash.nil?
      raise "libtorrent_flutter: native/PREBUILT_SHA256 has no line for #{zip_name}. " \
            "Add the hash from the release's SHA256SUMS."
    end
    zip_url  = "#{release_base}/#{zip_name}"
    zip_path = File.join(__dir__, '.ios-native-lib.zip')
    Pod::UI.puts "libtorrent_flutter: downloading prebuilt XCFramework from #{zip_url}"
    begin
      require 'open-uri'
      require 'fileutils'
      URI.open(zip_url) { |remote| File.binwrite(zip_path, remote.read) }
      actual_hash = Digest::SHA256.file(zip_path).hexdigest
      if actual_hash != expected_hash
        hash_mismatch = "libtorrent_flutter: #{zip_name} has SHA-256 #{actual_hash}, " \
                        "expected #{expected_hash} (native/PREBUILT_SHA256). Refusing to use it."
        raise hash_mismatch
      end
      # The zip root is the xcframework directory itself (Info.plist +
      # ios-arm64/ + ios-arm64_x86_64-simulator/), so extract straight into it.
      FileUtils.rm_rf(xcframework_absolute)
      FileUtils.mkdir_p(xcframework_absolute)
      system("/usr/bin/unzip -o -q '#{zip_path}' -d '#{xcframework_absolute}'") || raise('unzip failed')
      File.write(source_marker, marker)
    rescue => e
      raise if hash_mismatch # never fall back to an unverified copy
      Pod::UI.warn "libtorrent_flutter: prebuilt download failed (#{e.message})"
    ensure
      File.delete(zip_path) if File.exist?(zip_path)
    end
  end

  # Without the XCFramework the app still builds, but every torrent call fails
  # at runtime (no lt_* symbols for DynamicLibrary.process() to find) — so
  # fail `pod install` instead.
  unless File.exist?(File.join(xcframework_absolute, 'Info.plist'))
    raise "libtorrent_flutter: #{xcframework_path} is missing. Run the 'Build libtorrent native libs' " \
          "GitHub workflow so #{release_base} exists, or drop your own build into #{__dir__}."
  end

  s.vendored_frameworks = xcframework_path
  s.source_files = 'Classes/**/*.swift'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    # Force the linker to include all symbols from the static lib
    # so DynamicLibrary.process() can find them via dlsym().
    # Use conditional settings to select the correct XCFramework slice.
    'OTHER_LDFLAGS[sdk=iphoneos*]' => '-force_load "$(PODS_TARGET_SRCROOT)/libtorrent_flutter.xcframework/ios-arm64/liblibtorrent_flutter.a"',
    'OTHER_LDFLAGS[sdk=iphonesimulator*]' => '-force_load "$(PODS_TARGET_SRCROOT)/libtorrent_flutter.xcframework/ios-arm64_x86_64-simulator/liblibtorrent_flutter.a"',
  }
end
