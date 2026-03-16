import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  FirebaseFirestore.instance.settings = const Settings(
    persistenceEnabled: true,
  );
  runApp(const CivicIssueApp());
}

class CivicIssueApp extends StatelessWidget {
  const CivicIssueApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Civic Issue Reporting',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const _AuthGate(),
    );
  }
}

class _AuthGate extends StatelessWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (BuildContext context, AsyncSnapshot<User?> snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError) {
          return Scaffold(
            body: Center(child: Text('Auth error: ${snapshot.error}')),
          );
        }
        final User? user = snapshot.data;
        if (user == null) {
          return const LoginScreen();
        }
        return const FrontPageScreen();
      },
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _isRegisterMode = false;
  bool _isSubmitting = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final String email = _emailController.text.trim();
    final String password = _passwordController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      _showMessage('Please enter email and password.');
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    try {
      if (_isRegisterMode) {
        await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: email,
          password: password,
        );
      } else {
        await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: email,
          password: password,
        );
      }
    } on FirebaseAuthException catch (e) {
      _showMessage(e.message ?? 'Authentication failed.');
    } catch (e) {
      _showMessage('Authentication failed: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(Icons.account_circle, size: 80, color: Colors.blue),
                const SizedBox(height: 12),
                Text(
                  _isRegisterMode ? 'Create an account' : 'Welcome back',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Password',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _isSubmitting ? null : _submit,
                    child: _isSubmitting
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(_isRegisterMode ? 'Sign Up' : 'Sign In'),
                  ),
                ),
                const SizedBox(height: 10),
                TextButton(
                  onPressed: _isSubmitting
                      ? null
                      : () {
                          setState(() {
                            _isRegisterMode = !_isRegisterMode;
                          });
                        },
                  child: Text(
                    _isRegisterMode
                        ? 'Already have an account? Sign in'
                        : 'No account yet? Create one',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class IssueRecord {
  const IssueRecord({
    this.docId,
    required this.issueType,
    required this.description,
    required this.timestamp,
    required this.location,
    required this.imageUrls,
    required this.imageCount,
    required this.status,
  });

  final String? docId;
  final String issueType;
  final String description;
  final DateTime timestamp;
  final IssueLocation? location;
  final List<String> imageUrls;
  final int imageCount;
  final String status;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'issueType': issueType,
      'description': description,
      'timestamp': timestamp.toIso8601String(),
      'location': location == null
          ? null
          : <String, dynamic>{
              'latitude': location!.latitude,
              'longitude': location!.longitude,
            },
      'imageUrls': imageUrls,
      'imageCount': imageCount,
      'status': status,
    };
  }

  Map<String, dynamic> toFirestore() {
    return <String, dynamic>{
      'issueType': issueType,
      'description': description,
      'timestamp': Timestamp.fromDate(timestamp),
      'location': location == null
          ? null
          : <String, dynamic>{
              'latitude': location!.latitude,
              'longitude': location!.longitude,
            },
      'imageUrls': imageUrls,
      'imageCount': imageCount,
      'status': status,
    };
  }

  static IssueRecord fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic>? locationJson =
        json['location'] as Map<String, dynamic>?;
    return IssueRecord(
      docId: json['docId'] as String?,
      issueType: json['issueType'] as String? ?? 'Unknown issue',
      description: json['description'] as String? ?? '',
      timestamp:
          DateTime.tryParse(json['timestamp'] as String? ?? '') ??
          DateTime.now(),
      location: locationJson == null
          ? null
          : IssueLocation(
              latitude: (locationJson['latitude'] as num?)?.toDouble() ?? 0,
              longitude: (locationJson['longitude'] as num?)?.toDouble() ?? 0,
            ),
      imageUrls: _parseImageUrls(json['imageUrls']),
      imageCount: (json['imageCount'] as num?)?.toInt() ?? 0,
      status: json['status'] as String? ?? 'submitted_to_firestore',
    );
  }

  static IssueRecord fromFirestore(
    Map<String, dynamic> data, {
    String? docId,
  }) {
    final Map<String, dynamic>? locationJson =
        data['location'] as Map<String, dynamic>?;
    final DateTime timestamp = _parseTimestamp(data['timestamp']);
    return IssueRecord(
      docId: docId,
      issueType: data['issueType'] as String? ?? 'Unknown issue',
      description: data['description'] as String? ?? '',
      timestamp: timestamp,
      location: locationJson == null
          ? null
          : IssueLocation(
              latitude: (locationJson['latitude'] as num?)?.toDouble() ?? 0,
              longitude: (locationJson['longitude'] as num?)?.toDouble() ?? 0,
            ),
      imageUrls: _parseImageUrls(data['imageUrls']),
      imageCount: (data['imageCount'] as num?)?.toInt() ?? 0,
      status: data['status'] as String? ?? 'submitted_to_firestore',
    );
  }

  static List<String> _parseImageUrls(dynamic raw) {
    if (raw is List) {
      return raw.whereType<String>().toList();
    }
    return <String>[];
  }
}

IconData _issueIconData(String issueType) {
  switch (issueType) {
    case 'Overflowing Dustbins':
      return Icons.delete_outline;
    case 'Potholes':
      return Icons.construction;
    case 'Dark Streetlights':
      return Icons.lightbulb_outline;
    case 'Garbage Dumps':
      return Icons.delete_sweep;
    case 'Water Main Leaks':
      return Icons.water_drop;
    case 'Sewage Overflow':
      return Icons.warning_amber;
    case 'Dead Animal Disposal':
      return Icons.pets;
    case 'Debris/Construction Waste':
      return Icons.factory;
    case 'Clogged Storm Drains':
      return Icons.water_damage;
    case 'Broken Pavements':
      return Icons.square_foot;
    case 'Open Manholes':
      return Icons.report_problem;
    case 'Damaged Street Signs':
      return Icons.signpost;
    case 'Hanging Wires':
      return Icons.electrical_services;
    case 'Open Electric Boxes':
      return Icons.electrical_services_outlined;
    case 'Fallen Trees':
      return Icons.park;
    case 'Overgrown Bushes':
      return Icons.grass;
    case 'Footpath Encroachment':
      return Icons.directions_walk;
    case 'Illegal Hoardings':
      return Icons.campaign;
    case 'Abandoned Vehicles':
      return Icons.directions_car_filled;
    default:
      return Icons.report;
  }
}

Color _issueIconColor(String issueType) {
  switch (issueType) {
    case 'Overflowing Dustbins':
    case 'Garbage Dumps':
      return const Color(0xFF2F7F6B);
    case 'Potholes':
    case 'Broken Pavements':
      return const Color(0xFF7B5E3B);
    case 'Dark Streetlights':
      return const Color(0xFF6B5BD2);
    case 'Water Main Leaks':
    case 'Clogged Storm Drains':
      return const Color(0xFF1D7BB5);
    case 'Sewage Overflow':
      return const Color(0xFFB84A4A);
    case 'Dead Animal Disposal':
      return const Color(0xFF8A5A44);
    case 'Debris/Construction Waste':
      return const Color(0xFF8C6E4B);
    case 'Open Manholes':
      return const Color(0xFFB56A00);
    case 'Damaged Street Signs':
      return const Color(0xFF2C5F9E);
    case 'Hanging Wires':
    case 'Open Electric Boxes':
      return const Color(0xFFB04A6F);
    case 'Fallen Trees':
    case 'Overgrown Bushes':
      return const Color(0xFF2C8A4B);
    case 'Footpath Encroachment':
      return const Color(0xFF4E6A2A);
    case 'Illegal Hoardings':
      return const Color(0xFF8D2F46);
    case 'Abandoned Vehicles':
      return const Color(0xFF4A4A4A);
    default:
      return const Color(0xFF1E6B6E);
  }
}

DateTime _parseTimestamp(dynamic raw) {
  if (raw is Timestamp) {
    return raw.toDate();
  }
  if (raw is String) {
    return DateTime.tryParse(raw) ?? DateTime.now();
  }
  return DateTime.now();
}

Map<String, dynamic> _firestorePayloadFromRecord(IssueRecord record) {
  return <String, dynamic>{
    'issueType': record.issueType,
    'description': record.description,
    'timestamp': record.timestamp.toIso8601String(),
    'timestampDisplay': DateFormat(
      'dd MMM yyyy, hh:mm a',
    ).format(record.timestamp),
    'location': record.location == null
        ? null
        : <String, dynamic>{
            'latitude': record.location!.latitude,
            'longitude': record.location!.longitude,
          },
    'imageUrls': record.imageUrls,
    'imageCount': record.imageCount,
    'status': record.status,
    'source': 'flutter_mobile_app',
  };
}

Map<String, dynamic> _firestorePayloadForPreview(Map<String, dynamic> payload) {
  final Map<String, dynamic> preview = Map<String, dynamic>.from(payload);
  final dynamic rawTimestamp = preview['timestamp'];
  if (rawTimestamp is Timestamp) {
    preview['timestamp'] = rawTimestamp.toDate().toIso8601String();
  }
  return preview;
}

class StoredReport {
  const StoredReport({required this.record, required this.payloadJson});

  final IssueRecord record;
  final String payloadJson;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'record': record.toJson(),
      'payloadJson': payloadJson,
    };
  }

  static StoredReport fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic> recordJson =
        json['record'] as Map<String, dynamic>? ?? <String, dynamic>{};
    return StoredReport(
      record: IssueRecord.fromJson(recordJson),
      payloadJson: json['payloadJson'] as String? ?? '{}',
    );
  }
}

class FrontPageScreen extends StatefulWidget {
  const FrontPageScreen({super.key});

  @override
  State<FrontPageScreen> createState() => _FrontPageScreenState();
}

class _FrontPageScreenState extends State<FrontPageScreen> {
  final List<StoredReport> _reports = <StoredReport>[];
  static const Color _ink = Color(0xFF10223A);
  static const Color _accent = Color(0xFF1E6B6E);
  static const Color _cardTint = Color(0xFFF3F7F6);
  late final StreamSubscription<List<ConnectivityResult>> _connectivitySub;
  bool _isOnline = true;

  @override
  void initState() {
    super.initState();
    _initConnectivity();
    _connectivitySub = Connectivity().onConnectivityChanged.listen(
      _handleConnectivityChange,
    );
    _loadReports();
  }

  @override
  void dispose() {
    _connectivitySub.cancel();
    super.dispose();
  }

  Future<void> _initConnectivity() async {
    final List<ConnectivityResult> result = await Connectivity()
        .checkConnectivity();
    _handleConnectivityChange(result);
  }

  void _handleConnectivityChange(List<ConnectivityResult> result) {
    final bool online = !result.contains(ConnectivityResult.none);
    if (online == _isOnline) return;
    setState(() {
      _isOnline = online;
    });
    if (online) {
      _showSnack('Back online. Syncing reports.');
      _loadReports();
    } else {
      _showSnack('Device is offline. Reports will upload when online.');
    }
  }

  Future<void> _loadReports() async {
    try {
      final User? user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        if (mounted) {
          _showSnack('Please sign in to view your reports.');
        }
        return;
      }
      final QuerySnapshot<Map<String, dynamic>> snapshot =
          await FirebaseFirestore.instance
              .collection('reports')
              .where('userId', isEqualTo: user.uid)
              .orderBy('timestamp', descending: true)
              .get();

      final List<StoredReport> loaded = snapshot.docs.map((doc) {
        final Map<String, dynamic> data = doc.data();
        final IssueRecord record = IssueRecord.fromFirestore(
          data,
          docId: doc.id,
        );
        if (_isAcknowledgedStatus(record.status)) {
          return null;
        }
        final String payloadJson = const JsonEncoder.withIndent(
          '  ',
        ).convert(_firestorePayloadFromRecord(record));
        return StoredReport(record: record, payloadJson: payloadJson);
      }).whereType<StoredReport>().toList();

      if (!mounted) return;
      setState(() {
        _reports
          ..clear()
          ..addAll(loaded);
      });
    } catch (error) {
      if (!mounted) return;
      _showSnack('Failed to load reports from Firestore: $error');
    }
  }

  Future<void> _openNewReport() async {
    final StoredReport? report = await Navigator.of(context).push<StoredReport>(
      MaterialPageRoute<StoredReport>(
        builder: (BuildContext context) => const ComplaintScreen(
          returnOnSuccess: true,
          showSuccessMessage: false,
        ),
      ),
    );

    if (report == null || !mounted) return;

    setState(() {
      _reports.insert(0, report);
    });
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Issue report added to Firestore records.')),
    );
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  bool _isAcknowledgedStatus(String status) {
    final String normalized = status.trim().toLowerCase();
    return normalized.startsWith('acknowledged');
  }

  Future<bool> _confirmDelete(IssueRecord record) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Delete record?'),
          content: Text(
            'Delete "${record.issueType}"? This cannot be undone.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    return confirmed ?? false;
  }

  Future<void> _deleteReport(IssueRecord record) async {
    if (_isAcknowledgedStatus(record.status)) {
      _showSnack('This record was already acknowledged.');
      return;
    }
    if (record.docId == null) {
      _showSnack('Unable to delete this record.');
      return;
    }

    final bool confirmed = await _confirmDelete(record);
    if (!confirmed) return;

    try {
      await FirebaseFirestore.instance
          .collection('reports')
          .doc(record.docId)
          .delete();
      if (!mounted) return;
      _showSnack('Record deleted.');
      _loadReports();
    } catch (error) {
      if (!mounted) return;
      _showSnack('Failed to delete record: $error');
    }
  }

  Future<void> _signOut() async {
    try {
      await FirebaseAuth.instance.signOut();
    } catch (error) {
      _showSnack('Sign out failed: $error');
    }
  }

  Widget _buildRecordCard(
    IssueRecord record,
    int index, {
    VoidCallback? onTap,
  }) {
    final String formattedTime = DateFormat(
      'dd MMM yyyy, hh:mm a',
    ).format(record.timestamp);
    final String locationText = record.location == null
        ? 'Location: not provided'
        : 'Location: ${record.location!.latitude.toStringAsFixed(5)}, '
              '${record.location!.longitude.toStringAsFixed(5)}';
    final Color stripeColor = Color.lerp(
      _accent,
      const Color(0xFFE76F51),
      (index % 3) / 3,
    )!;

    final IconData issueIcon = _issueIconData(record.issueType);
    final Color issueColor = _issueIconColor(record.issueType);
    final bool canDelete =
        record.docId != null && !_isAcknowledgedStatus(record.status);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.06),
                blurRadius: 16,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Container(
              color: Colors.white,
              child: Row(
                children: <Widget>[
                  Container(width: 6, color: stripeColor),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Expanded(
                                child: Text(
                                  record.issueType,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                    color: _ink,
                                  ),
                                ),
                              ),
                              Icon(issueIcon, color: issueColor, size: 18),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: _cardTint,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  record.status.replaceAll('_', ' '),
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: _accent,
                                  ),
                                ),
                              ),
                              if (canDelete)
                                IconButton(
                                  tooltip: 'Delete record',
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    color: Color(0xFFE25555),
                                    size: 20,
                                  ),
                                  onPressed: () => _deleteReport(record),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            record.description,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: _ink),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 10,
                            runSpacing: 6,
                            children: <Widget>[
                              _InfoPill(
                                icon: Icons.schedule,
                                label: formattedTime,
                              ),
                              _InfoPill(
                                icon: Icons.photo,
                                label: '${record.imageCount} images',
                              ),
                              _InfoPill(icon: Icons.place, label: locationText),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openReportDetail(IssueRecord record) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => ReportDetailScreen(record: record),
      ),
    );
  }

  Widget _buildConnectivityBanner() {
    if (_isOnline) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3CD),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFFFE69C)),
      ),
      child: Row(
        children: const <Widget>[
          Icon(Icons.wifi_off, size: 18, color: Color(0xFF8A6D3B)),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Device is offline. Reports will upload when online.',
              style: TextStyle(
                color: Color(0xFF8A6D3B),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          colors: <Color>[Color(0xFFE6F4F1), Color(0xFFF8F3E7)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                height: 46,
                width: 46,
                decoration: BoxDecoration(
                  color: _accent.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.hub, color: _accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Welcome to Civic Issue Report',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: _ink,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Report local issues with photos, location, and details. '
            'Your recent reports appear below.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: _ink.withValues(alpha: 0.75),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              InkWell(
                onTap: _openNewReport,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Icon(Icons.add_circle, size: 18, color: _accent),
                      const SizedBox(width: 8),
                      Text(
                        'Tap + to add a new issue',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: _ink,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatsRow() {
    return Row(
      children: <Widget>[
        Expanded(
          child: _StatCard(
            label: 'Total Reports',
            value: _reports.length.toString(),
            icon: Icons.assignment,
            tint: const Color(0xFF1976D2),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _StatCard(
            label: 'Last Activity',
            value: _reports.isEmpty
                ? 'No reports'
                : DateFormat('dd MMM').format(_reports.first.record.timestamp),
            icon: Icons.access_time,
            tint: const Color(0xFF388E3C),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Civic Issue Reporter'),
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        actions: <Widget>[
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: _signOut,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openNewReport,
        icon: const Icon(Icons.add),
        label: const Text('New Report'),
        backgroundColor: _accent,
        foregroundColor: Colors.white,
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      body: SafeArea(
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: <Color>[Color(0xFFF8FBFA), Color(0xFFFDF6EE)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _buildConnectivityBanner(),
                _buildHeader(),
                const SizedBox(height: 16),
                _buildStatsRow(),
                const SizedBox(height: 18),
                StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: FirebaseAuth.instance.currentUser == null
                      ? const Stream<
                          QuerySnapshot<Map<String, dynamic>>
                        >.empty()
                      : FirebaseFirestore.instance
                            .collection('reports')
                            .where(
                              'userId',
                              isEqualTo: FirebaseAuth.instance.currentUser!.uid,
                            )
                            .orderBy('timestamp', descending: true)
                            .snapshots(),
                  builder:
                      (
                        BuildContext context,
                        AsyncSnapshot<QuerySnapshot<Map<String, dynamic>>>
                        snapshot,
                      ) {
                        final User? user = FirebaseAuth.instance.currentUser;
                        if (user == null) {
                          return const Text(
                            'Please sign in to view your reports.',
                          );
                        }
                        if (snapshot.connectionState ==
                            ConnectionState.waiting) {
                          return const Center(
                            child: Padding(
                              padding: EdgeInsets.symmetric(vertical: 16),
                              child: CircularProgressIndicator(),
                            ),
                          );
                        }
                        if (snapshot.hasError) {
                          return Text(
                            'Failed to load reports: ${snapshot.error}',
                          );
                        }

                        final List<QueryDocumentSnapshot<Map<String, dynamic>>>
                        docs =
                            snapshot.data?.docs ??
                            <QueryDocumentSnapshot<Map<String, dynamic>>>[];
                        final List<
                          QueryDocumentSnapshot<Map<String, dynamic>>
                        > visibleDocs = docs.where((doc) {
                          final String status =
                              doc.data()['status'] as String? ??
                              'submitted_to_firestore';
                          return !_isAcknowledgedStatus(status);
                        }).toList();

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                const Icon(
                                  Icons.history,
                                  size: 18,
                                  color: _ink,
                                ),
                                const SizedBox(width: 8),
                                const Text(
                                  'Previous Records',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: _ink,
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  '${visibleDocs.length} total',
                                  style: TextStyle(
                                    color: _ink.withValues(alpha: 0.6),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            if (visibleDocs.isEmpty)
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(14),
                                  color: Colors.white,
                                  border: Border.all(
                                    color: _accent.withValues(alpha: 0.15),
                                  ),
                                ),
                                child: Row(
                                  children: <Widget>[
                                    Container(
                                      height: 42,
                                      width: 42,
                                      decoration: BoxDecoration(
                                        color: _accent.withValues(alpha: 0.1),
                                        shape: BoxShape.circle,
                                      ),
                                      child: const Icon(
                                        Icons.inbox,
                                        color: _accent,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    const Expanded(
                                      child: Text(
                                        'No records yet. Submit your first issue report.',
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            else
                              ListView.builder(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                itemCount: visibleDocs.length,
                                itemBuilder: (BuildContext context, int index) {
                                  final Map<String, dynamic> data =
                                      visibleDocs[index].data();
                                  final IssueRecord record =
                                      IssueRecord.fromFirestore(
                                        data,
                                        docId: visibleDocs[index].id,
                                      );
                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 12),
                                    child: _buildRecordCard(
                                      record,
                                      index,
                                      onTap: () => _openReportDetail(record),
                                    ),
                                  );
                                },
                              ),
                          ],
                        );
                      },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.tint,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: Colors.white,
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: <Widget>[
          Container(
            height: 40,
            width: 40,
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: tint),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.black.withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoPill extends StatelessWidget {
  const _InfoPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F7),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 14, color: Colors.black54),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              style: const TextStyle(fontSize: 11, color: Colors.black87),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class ReportDetailScreen extends StatefulWidget {
  const ReportDetailScreen({super.key, required this.record});

  final IssueRecord record;

  @override
  State<ReportDetailScreen> createState() => _ReportDetailScreenState();
}

class _ReportDetailScreenState extends State<ReportDetailScreen> {
  static const Color _ink = Color(0xFF10223A);
  static const Color _accent = Color(0xFF1E6B6E);
  static const Color _cardTint = Color(0xFFF3F7F6);
  static const String _userAgent = 'civic_issue_management/0.1.0';

  String? _locationTitle;
  String? _locationSubtitle;
  bool _isLoadingLocation = false;
  int _activeImageIndex = 0;

  @override
  void initState() {
    super.initState();
    _loadLocationLabel();
  }

  Future<void> _loadLocationLabel() async {
    final IssueLocation? location = widget.record.location;
    if (location == null) return;

    setState(() {
      _isLoadingLocation = true;
    });

    try {
      final _LocationLabel? label = await _reverseGeocode(location);
      if (!mounted) return;
      setState(() {
        _locationTitle = label?.title;
        _locationSubtitle = label?.subtitle;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _locationTitle = null;
        _locationSubtitle = null;
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingLocation = false;
        });
      }
    }
  }

  Future<_LocationLabel?> _reverseGeocode(IssueLocation location) async {
    final Uri uri = Uri.parse(
      'https://nominatim.openstreetmap.org/reverse?format=jsonv2&addressdetails=1&lat=${location.latitude}&lon=${location.longitude}',
    );
    final http.Response response = await http.get(
      uri,
      headers: <String, String>{
        'User-Agent': _userAgent,
        'Accept': 'application/json',
      },
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return null;
    }

    final Map<String, dynamic> data =
        jsonDecode(response.body) as Map<String, dynamic>;
    final Map<String, dynamic>? address =
        data['address'] as Map<String, dynamic>?;
    final String? displayName = data['display_name'] as String?;

    String? pickValue(Map<String, dynamic>? address, List<String> keys) {
      if (address == null) return null;
      for (final String key in keys) {
        final String? value = address[key] as String?;
        if (value != null && value.trim().isNotEmpty) return value;
      }
      return null;
    }

    final String? area = pickValue(address, <String>[
      'neighbourhood',
      'suburb',
      'quarter',
      'city_district',
      'road',
      'hamlet',
      'village',
    ]);
    final String? city = pickValue(address, <String>[
      'city',
      'town',
      'village',
      'county',
    ]);
    final String? state = pickValue(address, <String>['state']);
    final String? country = pickValue(address, <String>['country']);
    final String? amenity = pickValue(address, <String>[
      'amenity',
      'tourism',
      'shop',
      'landmark',
    ]);
    final String? road = pickValue(address, <String>['road']);

    final List<String> titleParts = <String>[];
    if (area != null) titleParts.add(area);
    if (city != null && city != area) titleParts.add(city);
    if (state != null) titleParts.add(state);
    if (country != null && (titleParts.isEmpty || country != state)) {
      titleParts.add(country);
    }

    final String title =
        titleParts.isEmpty ? (displayName ?? 'Pinned location') : titleParts
            .join(', ');

    final List<String> nearby = <String>[];
    if (amenity != null) nearby.add(amenity);
    if (road != null && road != amenity) nearby.add(road);
    if (area != null && area != road && area != amenity) nearby.add(area);

    String? subtitle;
    if (nearby.isNotEmpty) {
      subtitle = 'Nearby: ${nearby.take(2).join(', ')}';
    } else if (displayName != null && displayName != title) {
      subtitle = displayName;
    }

    return _LocationLabel(title: title, subtitle: subtitle);
  }

  Widget _buildSectionCard({required Widget child}) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _buildImageGallery() {
    final List<String> images = widget.record.imageUrls;
    if (images.isEmpty) {
      return Container(
        height: 220,
        decoration: BoxDecoration(
          color: _cardTint,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _accent.withValues(alpha: 0.2)),
        ),
        child: const Center(
          child: Icon(Icons.photo, size: 36, color: _accent),
        ),
      );
    }

    return Column(
      children: <Widget>[
        SizedBox(
          height: 220,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: PageView.builder(
              itemCount: images.length,
              onPageChanged: (int index) {
                setState(() {
                  _activeImageIndex = index;
                });
              },
              itemBuilder: (BuildContext context, int index) {
                return Image.network(
                  images[index],
                  fit: BoxFit.cover,
                  loadingBuilder: (
                    BuildContext context,
                    Widget child,
                    ImageChunkEvent? loadingProgress,
                  ) {
                    if (loadingProgress == null) return child;
                    return Center(
                      child: SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          value: loadingProgress.expectedTotalBytes == null
                              ? null
                              : loadingProgress.cumulativeBytesLoaded /
                                    loadingProgress.expectedTotalBytes!,
                        ),
                      ),
                    );
                  },
                  errorBuilder: (
                    BuildContext context,
                    Object error,
                    StackTrace? stackTrace,
                  ) {
                    return const Center(
                      child: Icon(Icons.broken_image, size: 32),
                    );
                  },
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List<Widget>.generate(images.length, (int index) {
            final bool active = index == _activeImageIndex;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.symmetric(horizontal: 3),
              height: 6,
              width: active ? 18 : 6,
              decoration: BoxDecoration(
                color: active
                    ? _accent
                    : _accent.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(999),
              ),
            );
          }),
        ),
      ],
    );
  }

  Widget _buildLocationCard() {
    final IssueLocation? location = widget.record.location;
    if (location == null) {
      return _buildSectionCard(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: const <Widget>[
              Icon(Icons.place, color: _accent),
              SizedBox(width: 8),
              Expanded(child: Text('Location not provided.')),
            ],
          ),
        ),
      );
    }

    return _buildSectionCard(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: const <Widget>[
                Icon(Icons.place, color: _accent),
                SizedBox(width: 8),
                Text(
                  'Location Details',
                  style: TextStyle(fontWeight: FontWeight.bold, color: _ink),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_isLoadingLocation)
              const Text('Finding nearby area...')
            else if (_locationTitle != null)
              Text(
                _locationTitle!,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  color: _ink,
                ),
              )
            else
              const Text('Pinned location'),
            if (_locationSubtitle != null) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                _locationSubtitle!,
                style: TextStyle(color: _ink.withValues(alpha: 0.7)),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              'Lat: ${location.latitude.toStringAsFixed(5)}, '
              'Lng: ${location.longitude.toStringAsFixed(5)}',
              style: TextStyle(
                color: _ink.withValues(alpha: 0.65),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 12),
            InkWell(
              onTap: () => _openMap(location),
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                height: 160,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Stack(
                    children: <Widget>[
                      FlutterMap(
                        options: MapOptions(
                          initialCenter: LatLng(
                            location.latitude,
                            location.longitude,
                          ),
                          initialZoom: 16,
                          interactionOptions: const InteractionOptions(
                            flags: InteractiveFlag.none,
                          ),
                        ),
                        children: <Widget>[
                          TileLayer(
                            urlTemplate:
                                'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                            userAgentPackageName:
                                'com.example.civic_issue_management',
                          ),
                          MarkerLayer(
                            markers: <Marker>[
                              Marker(
                                point: LatLng(
                                  location.latitude,
                                  location.longitude,
                                ),
                                width: 36,
                                height: 36,
                                child: const Icon(
                                  Icons.location_pin,
                                  color: Colors.red,
                                  size: 36,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      Positioned(
                        right: 8,
                        top: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.9),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: const Text(
                            'Tap to open',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openMap(IssueLocation location) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            ReportMapScreen(location: location),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final IssueRecord record = widget.record;
    final String formattedTime = DateFormat(
      'dd MMM yyyy, hh:mm a',
    ).format(record.timestamp);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Record Details'),
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
      ),
      body: SafeArea(
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: <Color>[Color(0xFFF8FBFA), Color(0xFFFDF6EE)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              _buildSectionCard(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        record.issueType,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: _ink,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        record.description,
                        style: const TextStyle(color: _ink),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 10,
                        runSpacing: 6,
                        children: <Widget>[
                          _InfoPill(
                            icon: Icons.schedule,
                            label: formattedTime,
                          ),
                          _InfoPill(
                            icon: Icons.photo,
                            label: '${record.imageCount} images',
                          ),
                          _InfoPill(
                            icon: Icons.info_outline,
                            label: record.status.replaceAll('_', ' '),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _buildSectionCard(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Text(
                        'Issue Photos',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: _ink,
                        ),
                      ),
                      const SizedBox(height: 10),
                      _buildImageGallery(),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _buildLocationCard(),
            ],
          ),
        ),
      ),
    );
  }
}

class _LocationLabel {
  const _LocationLabel({required this.title, this.subtitle});

  final String title;
  final String? subtitle;
}

class ReportMapScreen extends StatelessWidget {
  const ReportMapScreen({super.key, required this.location});

  final IssueLocation location;

  @override
  Widget build(BuildContext context) {
    final LatLng center = LatLng(location.latitude, location.longitude);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Issue Location'),
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
      ),
      body: FlutterMap(
        options: MapOptions(initialCenter: center, initialZoom: 17),
        children: <Widget>[
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.example.civic_issue_management',
          ),
          MarkerLayer(
            markers: <Marker>[
              Marker(
                point: center,
                width: 48,
                height: 48,
                child: const Icon(
                  Icons.location_pin,
                  color: Colors.red,
                  size: 44,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class ComplaintScreen extends StatefulWidget {
  const ComplaintScreen({
    super.key,
    this.returnOnSuccess = false,
    this.showSuccessMessage = true,
  });

  final bool returnOnSuccess;
  final bool showSuccessMessage;

  @override
  State<ComplaintScreen> createState() => _ComplaintScreenState();
}

class IssueLocation {
  const IssueLocation({required this.latitude, required this.longitude});

  final double latitude;
  final double longitude;
}

class _ComplaintScreenState extends State<ComplaintScreen> {
  static const int _maxImages = 4;
  static const int _maxImageBytes = 1024 * 1024;
  static const Color _ink = Color(0xFF10223A);
  static const Color _accent = Color(0xFF1E6B6E);
  static const Color _cardTint = Color(0xFFF3F7F6);
  static const String _cloudinaryCloudName = 'dhf0zddtq';
  static const String _cloudinaryUploadPreset = 'CIVIC_ISSUE_IMAGES';
  static const String _cloudinaryFolder = 'civic-issues';
  final TextEditingController _descriptionController = TextEditingController();
  final ImagePicker _picker = ImagePicker();

  final List<String> _issueTypes = <String>[
    'Overflowing Dustbins',
    'Potholes',
    'Dark Streetlights',
    'Garbage Dumps',
    'Water Main Leaks',
    'Sewage Overflow',
    'Dead Animal Disposal',
    'Debris/Construction Waste',
    'Clogged Storm Drains',
    'Broken Pavements',
    'Open Manholes',
    'Damaged Street Signs',
    'Hanging Wires',
    'Open Electric Boxes',
    'Fallen Trees',
    'Overgrown Bushes',
    'Footpath Encroachment',
    'Illegal Hoardings',
    'Abandoned Vehicles',
    'Other civic issue',
  ];

  final List<XFile> _selectedImages = <XFile>[];
  String _selectedIssue = '';
  IssueLocation? _selectedLocation;
  DateTime? _capturedAt;
  bool _isSubmitting = false;
  String? _lastSentJson;

  Future<bool> _isOnline() async {
    final List<ConnectivityResult> result = await Connectivity()
        .checkConnectivity();
    return !result.contains(ConnectivityResult.none);
  }

  @override
  void initState() {
    super.initState();
    _selectedIssue = _issueTypes.isEmpty ? '' : _issueTypes.first;
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  // Image handling
  Future<void> _pickImage(ImageSource source) async {
    try {
      if (_selectedImages.length >= _maxImages) {
        _showMessage('You can attach up to $_maxImages images only.');
        return;
      }

      final XFile? image = await _picker.pickImage(
        source: source,
        imageQuality: 85,
        maxWidth: 1600,
        maxHeight: 1600,
      );
      if (image == null) return;

      final XFile? compressed = await _compressToLimit(image);
      if (compressed == null) {
        _showMessage('Could not compress image to 1 MB.');
        return;
      }

      if (!mounted) return;
      setState(() {
        _selectedImages.add(compressed);
        _capturedAt = DateTime.now();
      });

      await _captureLocation();
    } catch (error) {
      _showMessage('Image capture failed: $error');
    }
  }

  Future<void> _pickMultipleFromGallery() async {
    try {
      if (_selectedImages.length >= _maxImages) {
        _showMessage('You can attach up to $_maxImages images only.');
        return;
      }

      final List<XFile> images = await _picker.pickMultiImage(
        imageQuality: 85,
        maxWidth: 1600,
        maxHeight: 1600,
      );
      if (images.isEmpty) return;

      final int availableSlots = _maxImages - _selectedImages.length;
      final List<XFile> toProcess = images.take(availableSlots).toList();

      int failed = 0;
      final List<XFile> compressedImages = <XFile>[];
      for (final XFile image in toProcess) {
        final XFile? compressed = await _compressToLimit(image);
        if (compressed == null) {
          failed += 1;
        } else {
          compressedImages.add(compressed);
        }
      }

      if (!mounted) return;
      setState(() {
        _selectedImages.addAll(compressedImages);
        if (compressedImages.isNotEmpty) {
          _capturedAt = DateTime.now();
        }
      });

      if (images.length > availableSlots) {
        _showMessage(
          'Only $availableSlots images were added (limit $_maxImages).',
        );
      } else if (failed > 0) {
        _showMessage('$failed image(s) could not be compressed to 1 MB.');
      }

      if (compressedImages.isNotEmpty) {
        await _captureLocation();
      }
    } catch (error) {
      _showMessage('Image selection failed: $error');
    }
  }

  Future<XFile?> _compressToLimit(XFile source) async {
    final Uint8List bytes = await File(source.path).readAsBytes();
    final img.Image? decoded = img.decodeImage(bytes);
    if (decoded == null) {
      return null;
    }
    img.Image working = decoded;
    int quality = 90;
    List<int> encoded = img.encodeJpg(working, quality: quality);

    while (encoded.length > _maxImageBytes) {
      if (quality > 30) {
        quality -= 10;
      } else {
        final int newWidth = (working.width * 0.85).round();
        final int newHeight = (working.height * 0.85).round();
        if (newWidth < 320 || newHeight < 320) {
          break;
        }
        working = img.copyResize(working, width: newWidth, height: newHeight);
        quality = 80;
      }
      encoded = img.encodeJpg(working, quality: quality);
    }

    if (encoded.length > _maxImageBytes) {
      return null;
    }

    final Directory tempDir = await getTemporaryDirectory();
    final String fileName =
        'issue_${DateTime.now().millisecondsSinceEpoch}_${source.name}.jpg';
    final String targetPath = path.join(tempDir.path, fileName);
    final File output = File(targetPath);
    await output.writeAsBytes(encoded, flush: true);
    return XFile(
      output.path,
      name: path.basename(output.path),
      mimeType: 'image/jpeg',
      length: encoded.length,
    );
  }

  void _removeImageAt(int index) {
    setState(() {
      _selectedImages.removeAt(index);
      if (_selectedImages.isEmpty) {
        _capturedAt = null;
      }
    });
  }

  // Location handling
  Future<void> _captureLocation() async {
    final bool enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      _showMessage('Location services are turned off.');
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      _showMessage('Location permission is required to attach issue location.');
      return;
    }

    final Position position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    );

    if (!mounted) return;
    setState(() {
      _selectedLocation = IssueLocation(
        latitude: position.latitude,
        longitude: position.longitude,
      );
    });
  }

  Future<void> _chooseLocationOnMap() async {
    final IssueLocation? pickedLocation = await Navigator.of(context)
        .push<IssueLocation>(
          MaterialPageRoute<IssueLocation>(
            builder: (BuildContext context) => MapLocationPickerScreen(
              initialLocation:
                  _selectedLocation ??
                  const IssueLocation(latitude: 12.9716, longitude: 77.5946),
            ),
          ),
        );

    if (pickedLocation == null || !mounted) {
      return;
    }

    setState(() {
      _selectedLocation = pickedLocation;
    });
  }

  // Payload + submission
  Future<Map<String, dynamic>> _buildFirestorePayload(
    String description, {
    required String userId,
    required List<String> imageUrls,
  }) async {
    final DateTime reportTime = _capturedAt ?? DateTime.now();
    return <String, dynamic>{
      'issueType': _selectedIssue,
      'description': description,
      'timestamp': Timestamp.fromDate(reportTime),
      'timestampDisplay': DateFormat('dd MMM yyyy, hh:mm a').format(reportTime),
      'userId': userId,
      'location': _selectedLocation == null
          ? null
          : <String, dynamic>{
              'latitude': _selectedLocation!.latitude,
              'longitude': _selectedLocation!.longitude,
            },
      'imageUrls': imageUrls,
      'imageCount': _selectedImages.length,
      'status': 'submitted_to_firestore',
      'source': 'flutter_mobile_app',
    };
  }

  Future<String> _uploadToCloudinary(XFile image) async {
    final Uri endpoint = Uri.parse(
      'https://api.cloudinary.com/v1_1/$_cloudinaryCloudName/image/upload',
    );
    final http.MultipartRequest request = http.MultipartRequest(
      'POST',
      endpoint,
    );
    request.fields['upload_preset'] = _cloudinaryUploadPreset;
    request.fields['folder'] = _cloudinaryFolder;
    request.fields['tags'] = 'civic_issue';
    request.files.add(await http.MultipartFile.fromPath('file', image.path));

    final http.StreamedResponse response = await request.send();
    final String body = await response.stream.bytesToString();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Cloudinary upload failed (${response.statusCode}).');
    }
    final Map<String, dynamic> data =
        jsonDecode(body) as Map<String, dynamic>;
    final String? secureUrl = data['secure_url'] as String?;
    if (secureUrl == null || secureUrl.isEmpty) {
      throw Exception('Cloudinary upload response missing secure_url.');
    }
    return secureUrl;
  }

  Future<List<String>> _uploadSelectedImages() async {
    final List<String> urls = <String>[];
    for (final XFile image in _selectedImages) {
      final String url = await _uploadToCloudinary(image);
      urls.add(url);
    }
    return urls;
  }

  Future<void> _submitComplaint() async {
    final String trimmedDescription = _descriptionController.text.trim();
    final User? user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _showMessage('Please sign in before submitting a report.');
      return;
    }

    if (_selectedImages.isEmpty) {
      _showMessage('Please upload at least one photo of the issue.');
      return;
    }

    if (trimmedDescription.isEmpty) {
      _showMessage('Please add a description of the problem.');
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    try {
      final bool online = await _isOnline();
      if (!online) {
        _showMessage(
          'Device is offline. Please reconnect to upload photos.',
        );
        return;
      }

      if (_cloudinaryCloudName == 'YOUR_CLOUD_NAME' ||
          _cloudinaryUploadPreset == 'YOUR_UNSIGNED_UPLOAD_PRESET') {
        _showMessage('Set Cloudinary cloud name and upload preset first.');
        return;
      }

      final List<String> imageUrls = await _uploadSelectedImages();
      final Map<String, dynamic> payload = await _buildFirestorePayload(
        trimmedDescription,
        userId: user.uid,
        imageUrls: imageUrls,
      );
      final String payloadJson = const JsonEncoder.withIndent(
        '  ',
      ).convert(_firestorePayloadForPreview(payload));

      setState(() {
        _lastSentJson = payloadJson;
      });

      await FirebaseFirestore.instance.collection('reports').add(payload);

      if (!mounted) return;
      if (widget.showSuccessMessage) {
        _showMessage('Complaint saved to Firestore successfully.');
      }

      if (widget.returnOnSuccess && mounted) {
        Navigator.of(context).pop(
          StoredReport(
            record: IssueRecord(
              issueType: _selectedIssue,
              description: trimmedDescription,
              timestamp: _capturedAt ?? DateTime.now(),
              location: _selectedLocation,
              imageUrls: imageUrls,
              imageCount: _selectedImages.length,
              status: 'submitted_to_firestore',
            ),
            payloadJson: payloadJson,
          ),
        );
      }
    } catch (error) {
      _showMessage('Failed to save complaint: $error');
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String get _locationText {
    if (_selectedLocation == null) return 'Location not selected yet';
    return '${_selectedLocation!.latitude.toStringAsFixed(6)}, '
        '${_selectedLocation!.longitude.toStringAsFixed(6)}';
  }

  String get _timeText {
    final DateTime timestamp = _capturedAt ?? DateTime.now();
    return DateFormat('dd MMM yyyy, hh:mm a').format(timestamp);
  }

  String get _descriptionPreview {
    final String value = _descriptionController.text.trim();
    return value.isEmpty ? 'Not entered yet' : value;
  }

  Widget _buildImagePreview() {
    if (_selectedImages.isEmpty) {
      return Center(
        child: Text(
          'No image selected',
          style: TextStyle(color: _ink.withValues(alpha: 0.7)),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(12),
        itemCount: _selectedImages.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (BuildContext context, int index) {
          final XFile image = _selectedImages[index];
          return Stack(
            children: <Widget>[
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.file(
                  File(image.path),
                  width: 160,
                  height: 160,
                  fit: BoxFit.cover,
                  cacheWidth: 480,
                  cacheHeight: 480,
                ),
              ),
              Positioned(
                right: 6,
                top: 6,
                child: InkWell(
                  onTap: () => _removeImageAt(index),
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.close,
                      color: Colors.white,
                      size: 16,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildActionButtons() {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: <Widget>[
        FilledButton.icon(
          onPressed: () => _pickImage(ImageSource.camera),
          icon: const Icon(Icons.camera_alt),
          label: const Text('Capture'),
          style: FilledButton.styleFrom(
            backgroundColor: _accent,
            foregroundColor: Colors.white,
          ),
        ),
        OutlinedButton.icon(
          onPressed: _pickMultipleFromGallery,
          icon: const Icon(Icons.photo_library),
          label: const Text('Choose from Gallery'),
          style: OutlinedButton.styleFrom(
            foregroundColor: _accent,
            side: BorderSide(color: _accent.withValues(alpha: 0.4)),
          ),
        ),
        OutlinedButton.icon(
          onPressed: _captureLocation,
          icon: const Icon(Icons.location_searching),
          label: const Text('Refresh Location'),
          style: OutlinedButton.styleFrom(
            foregroundColor: _accent,
            side: BorderSide(color: _accent.withValues(alpha: 0.4)),
          ),
        ),
        OutlinedButton.icon(
          onPressed: _chooseLocationOnMap,
          icon: const Icon(Icons.map),
          label: const Text('Choose on Map'),
          style: OutlinedButton.styleFrom(
            foregroundColor: _accent,
            side: BorderSide(color: _accent.withValues(alpha: 0.4)),
          ),
        ),
      ],
    );
  }

  Widget _buildPreviewCard() {
    return _buildSectionCard(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Preview Before Sending',
              style: TextStyle(fontWeight: FontWeight.bold, color: _ink),
            ),
            const SizedBox(height: 8),
            Text('Issue: $_selectedIssue', style: const TextStyle(color: _ink)),
            const SizedBox(height: 6),
            Text('Timestamp: $_timeText', style: const TextStyle(color: _ink)),
            const SizedBox(height: 6),
            Text(
              'Location: $_locationText',
              style: const TextStyle(color: _ink),
            ),
            const SizedBox(height: 6),
            Text(
              'Description: $_descriptionPreview',
              style: const TextStyle(color: _ink),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLastSentPayload() {
    if (_lastSentJson == null) return const SizedBox.shrink();
    return _buildSectionCard(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Last Sent JSON Payload',
              style: TextStyle(fontWeight: FontWeight.bold, color: _ink),
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableText(
                _lastSentJson!,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          colors: <Color>[Color(0xFFE6F4F1), Color(0xFFF8F3E7)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                height: 46,
                width: 46,
                decoration: BoxDecoration(
                  color: _accent.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.edit_note, color: _accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Create a New Issue Report',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: _ink,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Add photos, choose a location, and describe the issue so the authority can act quickly.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: _ink.withValues(alpha: 0.75),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionCard({required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _accent.withValues(alpha: 0.08)),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Civic Issue Reporter'),
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
      ),
      body: SafeArea(
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: <Color>[Color(0xFFF8FBFA), Color(0xFFFDF6EE)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _buildHeaderCard(),
                const SizedBox(height: 16),
                _buildSectionCard(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const Text(
                          'Issue Photos',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: _ink,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Container(
                          height: 220,
                          width: double.infinity,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            color: _cardTint,
                            border: Border.all(
                              color: _accent.withValues(alpha: 0.2),
                            ),
                          ),
                          child: _buildImagePreview(),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Selected ${_selectedImages.length}/$_maxImages images',
                          style: TextStyle(
                            color: _ink.withValues(alpha: 0.7),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        _buildActionButtons(),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                _buildSectionCard(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const Text(
                          'Issue Details',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: _ink,
                          ),
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<String>(
                          initialValue: _selectedIssue,
                          decoration: InputDecoration(
                            labelText: 'Issue Category',
                            filled: true,
                            fillColor: Colors.white,
                            labelStyle: const TextStyle(color: _ink),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                color: _accent.withValues(alpha: 0.3),
                              ),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                color: _accent.withValues(alpha: 0.25),
                              ),
                            ),
                          ),
                          items: _issueTypes
                              .map(
                                (String issue) => DropdownMenuItem<String>(
                                  value: issue,
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 240,
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: <Widget>[
                                        Icon(
                                          _issueIconData(issue),
                                          color: _issueIconColor(issue),
                                          size: 18,
                                        ),
                                        const SizedBox(width: 8),
                                        Flexible(
                                          fit: FlexFit.loose,
                                          child: Text(
                                            issue,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (String? value) {
                            if (value == null) return;
                            setState(() {
                              _selectedIssue = value;
                            });
                          },
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _descriptionController,
                          maxLines: 4,
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            labelText: 'Problem Description',
                            hintText: 'Describe the issue in detail...',
                            filled: true,
                            fillColor: Colors.white,
                            labelStyle: const TextStyle(color: _ink),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                color: _accent.withValues(alpha: 0.3),
                              ),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                color: _accent.withValues(alpha: 0.25),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                _buildPreviewCard(),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _isSubmitting ? null : _submitComplaint,
                    style: FilledButton.styleFrom(
                      backgroundColor: _accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: _isSubmitting
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Send Complaint JSON to Authority'),
                  ),
                ),
                if (_lastSentJson != null) ...<Widget>[
                  const SizedBox(height: 16),
                  _buildLastSentPayload(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class MapLocationPickerScreen extends StatefulWidget {
  const MapLocationPickerScreen({super.key, required this.initialLocation});

  final IssueLocation initialLocation;

  @override
  State<MapLocationPickerScreen> createState() =>
      _MapLocationPickerScreenState();
}

class _MapLocationPickerScreenState extends State<MapLocationPickerScreen> {
  static final List<_RecentPlace> _recentPlaces = <_RecentPlace>[];
  late final MapController _mapController;
  late LatLng _pickedPoint;
  LatLng? _currentLocation;
  bool _hasUserMoved = false;
  bool _isSearching = false;
  String _pickedLabel = 'Pinned location';
  final TextEditingController _searchController = TextEditingController();
  final List<_PlaceSearchResult> _searchResults = <_PlaceSearchResult>[];

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    _pickedPoint = LatLng(
      widget.initialLocation.latitude,
      widget.initialLocation.longitude,
    );
    _loadCurrentLocation();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _onMapTap(TapPosition tapPosition, LatLng point) {
    setState(() {
      _hasUserMoved = true;
      _pickedPoint = point;
      _pickedLabel = 'Pinned location';
    });
  }

  void _confirmSelection() {
    _addRecentPlace(_pickedLabel, _pickedPoint);
    Navigator.of(context).pop(
      IssueLocation(
        latitude: _pickedPoint.latitude,
        longitude: _pickedPoint.longitude,
      ),
    );
  }

  Future<void> _loadCurrentLocation() async {
    final bool enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled || !mounted) return;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return;
    }

    final Position position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    );
    if (!mounted) return;

    final LatLng location = LatLng(position.latitude, position.longitude);
    setState(() {
      _currentLocation = location;
      if (!_hasUserMoved) {
        _pickedPoint = location;
        _pickedLabel = 'Current location';
      }
    });

    if (!_hasUserMoved) {
      _mapController.move(location, 16);
    }
  }

  Future<void> _searchPlaces(String query) async {
    final String trimmed = query.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _searchResults.clear();
      });
      return;
    }

    setState(() {
      _isSearching = true;
    });

    try {
      final Uri uri = Uri.parse(
        'https://nominatim.openstreetmap.org/search?format=json&limit=5&addressdetails=1&q=${Uri.encodeQueryComponent(trimmed)}',
      );
      final http.Response response = await http.get(
        uri,
        headers: <String, String>{
          'User-Agent': 'civic_issue_management/0.1.0',
          'Accept': 'application/json',
        },
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (!mounted) return;
        _showSnack('Search failed (${response.statusCode}).');
        return;
      }

      final List<dynamic> data = jsonDecode(response.body) as List<dynamic>;
      final List<_PlaceSearchResult> results = data
          .map((dynamic raw) => _PlaceSearchResult.fromJson(raw))
          .where((result) => result != null)
          .cast<_PlaceSearchResult>()
          .toList();

      if (!mounted) return;
      setState(() {
        _searchResults
          ..clear()
          ..addAll(results);
      });
    } catch (error) {
      if (!mounted) return;
      _showSnack('Search error: $error');
    } finally {
      if (mounted) {
        setState(() {
          _isSearching = false;
        });
      }
    }
  }

  void _selectSearchResult(_PlaceSearchResult result) {
    setState(() {
      _pickedPoint = result.point;
      _pickedLabel = result.label;
      _hasUserMoved = true;
      _searchResults.clear();
      _searchController.text = result.label;
    });
    _mapController.move(result.point, 16);
  }

  void _addRecentPlace(String label, LatLng point) {
    _recentPlaces.removeWhere((place) => place.label == label);
    _recentPlaces.insert(0, _RecentPlace(label: label, point: point));
    if (_recentPlaces.length > 5) {
      _recentPlaces.removeRange(5, _recentPlaces.length);
    }
  }

  void _useRecentPlace(_RecentPlace place) {
    setState(() {
      _pickedPoint = place.point;
      _pickedLabel = place.label;
      _hasUserMoved = true;
    });
    _mapController.move(place.point, 16);
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Choose Issue Location'),
        actions: <Widget>[
          TextButton(
            onPressed: _confirmSelection,
            child: const Text('Use This'),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                TextField(
                  controller: _searchController,
                  textInputAction: TextInputAction.search,
                  onSubmitted: _searchPlaces,
                  decoration: InputDecoration(
                    labelText: 'Search a place',
                    hintText: 'Area, landmark, address',
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _isSearching
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                              height: 16,
                              width: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchController.clear();
                              setState(() {
                                _searchResults.clear();
                              });
                            },
                          ),
                  ),
                ),
                if (_searchResults.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 8),
                  Card(
                    child: ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _searchResults.length,
                      itemBuilder: (BuildContext context, int index) {
                        final _PlaceSearchResult result = _searchResults[index];
                        return ListTile(
                          title: Text(result.label),
                          onTap: () => _selectSearchResult(result),
                        );
                      },
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    FilledButton.icon(
                      onPressed: _currentLocation == null
                          ? _loadCurrentLocation
                          : () {
                              setState(() {
                                _pickedPoint = _currentLocation!;
                                _pickedLabel = 'Current location';
                                _hasUserMoved = true;
                              });
                              _mapController.move(_currentLocation!, 16);
                            },
                      icon: const Icon(Icons.my_location),
                      label: const Text('Use Current'),
                    ),
                    const SizedBox(width: 12),
                    if (_recentPlaces.isNotEmpty)
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Wrap(
                            spacing: 8,
                            children: _recentPlaces
                                .map(
                                  (_RecentPlace place) => ActionChip(
                                    label: Text(place.label),
                                    onPressed: () => _useRecentPlace(place),
                                  ),
                                )
                                .toList(),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: _pickedPoint,
                initialZoom: 16,
                onTap: _onMapTap,
              ),
              children: <Widget>[
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.example.civic_issue_management',
                ),
                MarkerLayer(
                  markers: <Marker>[
                    if (_currentLocation != null)
                      Marker(
                        point: _currentLocation!,
                        width: 24,
                        height: 24,
                        child: const Icon(
                          Icons.radio_button_checked,
                          color: Colors.blue,
                          size: 20,
                        ),
                      ),
                    Marker(
                      point: _pickedPoint,
                      width: 44,
                      height: 44,
                      child: const Icon(
                        Icons.location_pin,
                        size: 44,
                        color: Colors.red,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    'Selected: ${_pickedPoint.latitude.toStringAsFixed(6)}, ${_pickedPoint.longitude.toStringAsFixed(6)}',
                  ),
                ),
                FilledButton(
                  onPressed: _confirmSelection,
                  child: const Text('Confirm'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PlaceSearchResult {
  const _PlaceSearchResult({required this.label, required this.point});

  final String label;
  final LatLng point;

  static _PlaceSearchResult? fromJson(dynamic raw) {
    if (raw is! Map<String, dynamic>) return null;
    final String? displayName = raw['display_name'] as String?;
    final String? latRaw = raw['lat'] as String?;
    final String? lonRaw = raw['lon'] as String?;
    if (displayName == null || latRaw == null || lonRaw == null) {
      return null;
    }
    final double? lat = double.tryParse(latRaw);
    final double? lon = double.tryParse(lonRaw);
    if (lat == null || lon == null) return null;
    return _PlaceSearchResult(label: displayName, point: LatLng(lat, lon));
  }
}

class _RecentPlace {
  const _RecentPlace({required this.label, required this.point});

  final String label;
  final LatLng point;
}
