const fs = require('fs');
const path = require('path');

const rootPackagePath = path.join(__dirname, 'package.json');
const desktopPackagePath = path.join(__dirname, 'apps', 'desktop', 'package.json');
const flutterPubspecPath = path.join(__dirname, 'apps', 'flutter_client', 'pubspec.yaml');

if (!fs.existsSync(flutterPubspecPath)) {
  console.error(`Could not find ${flutterPubspecPath}`);
  process.exit(1);
}

// 1. Read from Flutter pubspec.yaml (Source of truth)
const pubspecContent = fs.readFileSync(flutterPubspecPath, 'utf8');
const versionRegex = /^version:\s*([0-9]+\.[0-9]+\.[0-9]+)(\+[0-9]+)?/m;
const match = pubspecContent.match(versionRegex);

if (!match) {
  console.error('Error: Could not parse version from pubspec.yaml');
  process.exit(1);
}

const newVersion = match[1]; // Extract the base version (e.g. 1.0.29) ignoring the build number (+20)

// 2. Update Root package.json
if (fs.existsSync(rootPackagePath)) {
  const rootPackage = JSON.parse(fs.readFileSync(rootPackagePath, 'utf8'));
  rootPackage.version = newVersion;
  fs.writeFileSync(rootPackagePath, JSON.stringify(rootPackage, null, 2) + '\n');
  console.log(`Updated root package.json version to ${newVersion}`);
}

// 3. Update Desktop package.json
if (fs.existsSync(desktopPackagePath)) {
  const desktopPackage = JSON.parse(fs.readFileSync(desktopPackagePath, 'utf8'));
  desktopPackage.version = newVersion;
  fs.writeFileSync(desktopPackagePath, JSON.stringify(desktopPackage, null, 2) + '\n');
  console.log(`Updated desktop package.json version to ${newVersion}`);
} else {
  console.warn(`Could not find ${desktopPackagePath}`);
}
