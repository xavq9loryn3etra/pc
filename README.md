# Popcorn Monorepo

## Versioning & Synchronization
This project uses the Flutter app's `pubspec.yaml` as the absolute source of truth for application versioning.

To update the version across **all** apps (Desktop and Flutter apps):
1. Update the version value in `apps/flutter_client/pubspec.yaml` (e.g., `1.1.0+21`).
2. Run the synchronization script from the terminal in the root folder (`p:\PERSONAL\IDEAS\pc`):
   ```bash
   npm run sync-version
   ```
3. The script will automatically evaluate the version, strip the build number (`+21`), and update both the root `package.json` and the Desktop app's `package.json` with the base version (`1.1.0`).

## Development Commands

### 🖥️ Desktop (Electron)
Run these from the **root folder**:
*   **Dev Mode**: `npm run dev:desktop`
*   **Build**: `npm run build:desktop`

### 📱 Mobile (Flutter)
Run these from the **`apps/flutter_client`** folder:
*   **Run App**: `flutter run`
*   **Get Packages**: `flutter pub get`
*   **Generate Launcher Icons**: 
    ```bash
    dart run flutter_launcher_icons
    ```
    *(Generates Android, iOS, and Windows app icons from `assets/icon.png` and `assets/icon-transparent.png`)*

## Project Structure
*   `apps/desktop`: Electron/Vite desktop application.
*   `apps/flutter_client`: Flutter mobile/desktop application.
*   `sync-version.js`: Synchronization script for monorepo versioning.
