# Civic Issue Management

A Flutter-based civic issue reporting app that lets residents report everyday municipal issues with location, images, and description. Reports are stored in Firebase and can also be sent as JSON to a lightweight desktop “authority” server for local viewing.

## How the App Works

1. Sign in or create an account using email/password.
2. Create a new report by choosing a category, adding a description, attaching images, and selecting a location on the map or via GPS.
3. Submit the report, which is saved to Firestore and can optionally be sent as JSON to a local desktop server endpoint.
4. View submitted reports in a timeline with status, timestamp, images, and location details.
5. Use the app offline with Firestore persistence and automatic sync when connectivity returns.

## Tech Stack

- **Flutter (Dart)**: Mobile UI and core application logic.
- **Firebase Auth**: Email/password authentication.
- **Firestore**: Report storage with offline persistence.
- **flutter_map + OpenStreetMap tiles**: Map UI for location selection.
- **Nominatim**: Place search for map lookup.
- **geolocator**: GPS location.
- **image_picker**: Camera/gallery image capture.
- **image**: Local image processing.
- **http**: API requests.
- **Desktop receiver (optional, Node.js)**: `desktop_server/server.js`
- **Desktop receiver (optional, Python)**: `desktop_server/server.py`

## Run the Flutter App

From the project root:

```powershell
flutter pub get
flutter run
```

> Firebase initialization uses `lib/firebase_options.dart`. Make sure the Firebase project is set up for your target platform.

## Run Desktop Receiver and Open in Browser

From the project root:

1. Start desktop server (Node.js):
```powershell
cd desktop_server
npm install
npm start
```

Or start desktop server (Python):
```powershell
cd desktop_server
python server.py
```

2. Open this in desktop browser:
```text
http://localhost:8080/
```

3. In the Flutter app, set `Desktop Server URL` to:
- Android emulator: `http://10.0.2.2:8080/report`
- Real phone on same Wi-Fi: `http://<your-desktop-lan-ip>:8080/report`

4. Upload/capture photo and send complaint.
   The browser page auto-refreshes and shows received details.

Useful endpoints:
- Dashboard: `http://localhost:8080/`
- Health: `http://localhost:8080/health`
- Raw JSON reports: `http://localhost:8080/api/reports`
