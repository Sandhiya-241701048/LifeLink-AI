# LifeLink — Blood Donation & Donor Connection App

LifeLink is a Flutter-based application designed to help connect people who need blood with potential blood donors. It aims to make donor discovery and blood-request coordination easier through a simple mobile app experience.

## Project Overview

Finding a suitable blood donor quickly can be challenging. LifeLink provides a common platform for users to explore donor information and coordinate blood requests. The app is built with Flutter and uses Firebase services for backend functionality.

## Features

- **Donor discovery:** Browse and search for potential blood donors.
- **Priority-based donor search:** Help users focus on relevant donor results.
- **Area search and suggestions:** Search by location/area using available suggestions.
- **Patient and donor workflows:** Support separate app experiences for people requesting blood and people donating.
- **Hospital donor view:** View donor information in the hospital-related section of the app.
- **Firebase integration:** Firebase-backed functionality depends on the services enabled in the project's configuration.
- **Cross-platform Flutter project:** Includes platform folders for Android, iOS, web, Windows, Linux, and macOS.

> **Note:** Feature availability depends on the current app and Firebase configuration. LifeLink is a student project and should not replace emergency medical services or official hospital blood-bank procedures.

## Tech Stack

- **Frontend:** Flutter, Dart
- **Backend / cloud services:** Firebase
- **Database:** Cloud Firestore, if configured for the current Firebase project
- **Platforms:** Android, iOS, Web, Windows, Linux, macOS

## Getting Started

### Prerequisites

Install the following:

- [Flutter SDK](https://docs.flutter.dev/get-started/install)
- [Git](https://git-scm.com/downloads)
- [Visual Studio Code](https://code.visualstudio.com/) or another Flutter-compatible IDE

### 1. Clone the repository

Replace `YOUR-USERNAME` and `LifeLink` with your actual GitHub username and repository name if they differ:

```bash
git clone https://github.com/YOUR-USERNAME/LifeLink.git
cd LifeLink
```

### 2. Install dependencies

```bash
flutter pub get
```

### 3. Configure Firebase

The app uses Firebase configuration files. To run it with your own Firebase project, configure Firebase for the platforms you intend to run, following the [FlutterFire documentation](https://firebase.google.com/docs/flutter/setup).

Do not commit service-account private keys, admin credentials, passwords, or other secrets to the repository.

### 4. Run the app

Connect an Android device, start an emulator, or select another supported device, then run:

```bash
flutter run
```

To list available devices:

```bash
flutter devices
```

## Project Structure

```text
LifeLink/
├── android/          # Android platform project
├── ios/              # iOS platform project
├── lib/
│   ├── main.dart     # Main Flutter application
│   └── firebase_options.dart
├── linux/            # Linux platform project
├── macos/             # macOS platform project
├── test/              # Flutter tests
├── web/               # Web platform project
├── windows/           # Windows platform project
├── pubspec.yaml       # Dependencies and Flutter project metadata
└── README.md
```

## Development Commands

```bash
# Install packages
flutter pub get

# Check for Dart/Flutter issues
flutter analyze

# Run tests
flutter test

# Run the app
flutter run
```

## Privacy and Safety

- Use only test or authorized data during development.
- Do not publish passwords, private keys, Firebase service-account files, or other secrets.
- Handle donor contact details and other personal information responsibly.
- In an emergency, contact local emergency services or a hospital/blood bank directly.

## Future Improvements

Potential future enhancements include improved donor availability handling, stronger validation, accessibility improvements, and expanded testing.

## Contributors

Developed as a student project. Add the names of your team members and institution here if appropriate.

## License

No license has been specified yet. Unless you add a license file, others should not assume they have permission to reuse, modify, or distribute this project.
