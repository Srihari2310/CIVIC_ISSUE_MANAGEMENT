# civic_issue_management

A new Flutter project.
# CIVIC_ISSUE_MANAGEMENT
CIVIC ISSUE MANAGEMENT SYSTEM FOR PEOPLE TO FILE A COMPLAINT ON EVERYDAY CIVIC ISSUES TO THE MUNICIPAL CORPORATIONS 

## Run desktop receiver and open in browser

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

3. In Flutter app, set `Desktop Server URL` to:
- Android emulator: `http://10.0.2.2:8080/report`
- Real phone on same Wi-Fi: `http://<your-desktop-lan-ip>:8080/report`

4. Upload/capture photo and send complaint.
   The browser page auto-refreshes and shows received details.

Useful endpoints:
- Dashboard: `http://localhost:8080/`
- Health: `http://localhost:8080/health`
- Raw JSON reports: `http://localhost:8080/api/reports`
