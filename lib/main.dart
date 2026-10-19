import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'firebase_options.dart';

import 'package:geolocator/geolocator.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const LifeLinkApp());
}

// ============================================================
// MODELS + FIRESTORE DATA HELPERS
// ============================================================

// Coordinates for the supported Chennai hospital suggestions.
// These are map pins for the listed hospital locations, not device GPS.
// For any other hospital, configure its real latitude/longitude in the Hospital
// role profile rather than substituting the phone's current location.
LatLng? coordinatesForHospital(String name) {
  final key = name.trim().toLowerCase();
  const entries = <String, LatLng>{
    'apollo hospital': LatLng(13.0067, 80.2206),
    'apollo hospitals greams road': LatLng(13.0634, 80.2518),
    'apollo first med hospitals': LatLng(13.0845, 80.2101),
    'billroth hospital': LatLng(13.0835, 80.2215),
    'billroth hospitals shenoy nagar': LatLng(13.0783, 80.2255),
    'fortis malar hospital': LatLng(13.0068, 80.2550),
    'government general hospital': LatLng(13.0830, 80.2785),
    'government kilpauk medical college hospital': LatLng(13.0788, 80.2420),
    'miot international': LatLng(13.0317, 80.1748),
    'rajiv gandhi government general hospital': LatLng(13.0830, 80.2785),
    'sims hospital': LatLng(13.0520, 80.2120),
    'sri ramachandra medical centre': LatLng(13.0387, 80.1406),
    'srm general hospital': LatLng(12.8230, 80.0444),
    'stanley medical college hospital': LatLng(13.1050, 80.2870),
    'vijaya hospital': LatLng(13.0525, 80.2090),
  };
  return entries[key];
}

class BloodRequest {
  String? id;
  String patientName;
  String bloodGroup;
  int units;
  String hospital;
  bool emergency;
  String status;
  String? patientId;
  String? createdBy;
  DateTime? createdAt;
  double? patientLatitude;
  double? patientLongitude;
  String? donorId;
  String? donorName;

  BloodRequest({
    this.id,
    required this.patientName,
    required this.bloodGroup,
    required this.units,
    required this.hospital,
    required this.emergency,
    this.status = 'Pending',
    this.patientId,
    this.createdBy,
    this.createdAt,
    this.patientLatitude,
    this.patientLongitude,
    this.donorId,
    this.donorName,
  });

  factory BloodRequest.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? {};
    final created = data['createdAt'];
    return BloodRequest(
      id: doc.id,
      patientName: (() {
        final candidates = [data['patientName'], data['patient'], data['name']];
        for (final candidate in candidates) {
          final value = candidate?.toString().trim() ?? '';
          if (value.isNotEmpty && value.toLowerCase() != 'patient')
            return value;
        }
        return 'Patient name unavailable';
      })(),
      bloodGroup: data['bloodGroup']?.toString() ?? 'O+',
      units: (data['units'] as num?)?.toInt() ?? 1,
      hospital: data['hospital']?.toString() ?? '',
      emergency: data['emergency'] == true,
      status: data['status']?.toString() ?? 'Pending',
      patientId: data['patientId']?.toString(),
      createdBy: data['createdBy']?.toString(),
      createdAt: created is Timestamp ? created.toDate() : null,
      patientLatitude: (data['patientLatitude'] as num?)?.toDouble(),
      patientLongitude: (data['patientLongitude'] as num?)?.toDouble(),
      donorId: data['donorId']?.toString(),
      donorName: data['donorName']?.toString(),
    );
  }

  Map<String, dynamic> toMap({bool includeServerTimestamps = true}) {
    return {
      'patientId': patientId,
      'patientName': patientName,
      'bloodGroup': bloodGroup,
      'units': units,
      'hospital': hospital,
      'emergency': emergency,
      'status': status,
      'createdBy': createdBy,
      if (patientLatitude != null) 'patientLatitude': patientLatitude,
      if (patientLongitude != null) 'patientLongitude': patientLongitude,
      if (donorId != null) 'donorId': donorId,
      if (donorName != null) 'donorName': donorName,
      if (includeServerTimestamps) 'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }
}

class Donor {
  String? id;
  String name;
  String bloodGroup;
  int donationCount;
  bool available;
  double latitude;
  double longitude;
  String city;

  Donor({
    this.id,
    required this.name,
    required this.bloodGroup,
    required this.donationCount,
    required this.available,
    required this.latitude,
    required this.longitude,
    this.city = '',
  });

  factory Donor.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? {};
    return Donor(
      id: doc.id,
      name: data['name']?.toString() ?? 'Donor',
      bloodGroup: data['bloodGroup']?.toString() ?? 'O+',
      donationCount: (data['donationCount'] as num?)?.toInt() ?? 0,
      available: data['available'] != false,
      latitude: (data['latitude'] as num?)?.toDouble() ?? 0,
      longitude: (data['longitude'] as num?)?.toDouble() ?? 0,
      city: data['city']?.toString() ?? '',
    );
  }

  factory Donor.fromRoleProfile(
    DocumentSnapshot<Map<String, dynamic>> doc,
    Map<String, dynamic> profile,
  ) {
    return Donor(
      id: doc.id,
      name: profile['name']?.toString() ?? 'Donor',
      bloodGroup: profile['bloodGroup']?.toString() ?? 'O+',
      donationCount: (profile['donationCount'] as num?)?.toInt() ?? 0,
      available: profile['available'] != false,
      latitude: (profile['latitude'] as num?)?.toDouble() ?? 0,
      longitude: (profile['longitude'] as num?)?.toDouble() ?? 0,
      city: profile['city']?.toString() ?? '',
    );
  }
}

// Hospital names are only autocomplete suggestions. User/account data is
// always stored in Firestore and is never represented by demo users.
const List<String> hospitalNames = [
  'Apollo Hospital',
  'Apollo Hospitals Greams Road',
  'Apollo First Med Hospitals',
  'Billroth Hospital',
  'Billroth Hospitals Shenoy Nagar',
  'Fortis Malar Hospital',
  'Government General Hospital',
  'Government Kilpauk Medical College Hospital',
  'MIOT International',
  'Rajiv Gandhi Government General Hospital',
  'SIMS Hospital',
  'Sri Ramachandra Medical Centre',
  'SRM General Hospital',
  'Stanley Medical College Hospital',
  'Vijaya Hospital',
];

// Kept only as an in-memory cache for the currently visible request.
// Firestore is the source of truth and the request is reloaded after app restart.
BloodRequest? activeBloodRequest;
String? activeBloodRequestId;

const List<String> allBloodGroups = [
  'A+',
  'A-',
  'B+',
  'B-',
  'AB+',
  'AB-',
  'O+',
  'O-',
];

Future<BloodRequest?> fetchLatestBloodRequest({
  String? ownerId,
  bool pendingOnly = false,
  String? donorBloodGroup,
}) async {
  try {
    Query<Map<String, dynamic>> query = FirebaseFirestore.instance.collection(
      'blood_requests',
    );

    if (ownerId != null) {
      query = query.where('createdBy', isEqualTo: ownerId);
    }
    if (pendingOnly) {
      query = query.where('status', isEqualTo: 'Pending');
    }

    final snapshot = await query.limit(50).get();
    if (snapshot.docs.isEmpty) return null;

    var requests = snapshot.docs.map(BloodRequest.fromDoc).toList();

    // Do not change Firestore rules or the existing query structure.
    // For donors, only show requests for their exact registered group.
    if (donorBloodGroup != null && donorBloodGroup.trim().isNotEmpty) {
      final currentUser = FirebaseAuth.instance.currentUser;
      requests = requests.where((request) {
        final isOwn =
            currentUser != null &&
            (request.createdBy == currentUser.uid ||
                request.patientId == currentUser.uid);
        return !isOwn &&
            canDonorDonateTo(
              donorBloodGroup.trim().toUpperCase(),
              request.bloodGroup.trim().toUpperCase(),
            );
      }).toList();
    }

    if (requests.isEmpty) return null;

    requests.sort((a, b) {
      final ad = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bd = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bd.compareTo(ad);
    });

    return requests.first;
  } catch (_) {
    return null;
  }
}

Future<void> refreshActiveBloodRequest({
  String? ownerId,
  bool pendingOnly = false,
  String? donorBloodGroup,
}) async {
  final request = await fetchLatestBloodRequest(
    ownerId: ownerId,
    pendingOnly: pendingOnly,
    donorBloodGroup: donorBloodGroup,
  );
  activeBloodRequest = request;
  activeBloodRequestId = request?.id;
}

Future<void> updateBloodRequestStatus(String status) async {
  final id = activeBloodRequestId ?? activeBloodRequest?.id;
  if (id == null) return;

  await FirebaseFirestore.instance.collection('blood_requests').doc(id).update({
    'status': status,
    'updatedAt': FieldValue.serverTimestamp(),
  });
  activeBloodRequest?.status = status;
}

Future<void> updateRoleProfileFields(
  String role,
  Map<String, dynamic> fields,
) async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return;

  final userRef = FirebaseFirestore.instance.collection('users').doc(user.uid);
  final snapshot = await userRef.get();
  final data = snapshot.data() ?? {};
  final rawProfiles = data['roleProfiles'];
  final profiles = rawProfiles is Map
      ? Map<String, dynamic>.from(rawProfiles)
      : <String, dynamic>{};
  final rawRoleProfile = profiles[role];
  final roleProfile = rawRoleProfile is Map
      ? Map<String, dynamic>.from(rawRoleProfile)
      : <String, dynamic>{};

  roleProfile.addAll(fields);
  profiles[role] = roleProfile;

  await userRef.set({'roleProfiles': profiles}, SetOptions(merge: true));

  if (data['role']?.toString() == role) {
    await userRef.set(fields, SetOptions(merge: true));
  }
}

const List<String> chennaiAreas = [
  'All Areas',
  'Anna Nagar',
  'T Nagar',
  'West Mambalam',
  'Adyar',
  'Velachery',
  'Nungambakkam',
  'Kilpauk',
  'Egmore',
  'Guindy',
  'Saidapet',
  'Ashok Nagar',
  'K K Nagar',
  'Porur',
  'Ambattur',
  'Mogappair',
  'Sholinganallur',
  'Perungudi',
  'Tharamani',
  'Tambaram',
  'Chromepet',
  'Pallavaram',
];

const List<Map<String, dynamic>> demoDonorData = [
  {
    'id': 'demo_anna_1',
    'name': 'Arjun',
    'bloodGroup': 'A+',
    'donationCount': 12,
    'available': true,
    'city': 'Anna Nagar',
    'latitude': 13.0878,
    'longitude': 80.2085,
  },
  {
    'id': 'demo_anna_2',
    'name': 'Meena',
    'bloodGroup': 'B+',
    'donationCount': 10,
    'available': true,
    'city': 'Anna Nagar',
    'latitude': 13.0850,
    'longitude': 80.2102,
  },
  {
    'id': 'demo_anna_3',
    'name': 'Karthik',
    'bloodGroup': 'O+',
    'donationCount': 8,
    'available': true,
    'city': 'Anna Nagar',
    'latitude': 13.0912,
    'longitude': 80.2048,
  },
  {
    'id': 'demo_tnagar_1',
    'name': 'Priya',
    'bloodGroup': 'A+',
    'donationCount': 12,
    'available': true,
    'city': 'T Nagar',
    'latitude': 13.0418,
    'longitude': 80.2341,
  },
  {
    'id': 'demo_tnagar_2',
    'name': 'Rahul',
    'bloodGroup': 'B+',
    'donationCount': 9,
    'available': true,
    'city': 'T Nagar',
    'latitude': 13.0369,
    'longitude': 80.2367,
  },
  {
    'id': 'demo_tnagar_3',
    'name': 'Divya',
    'bloodGroup': 'O+',
    'donationCount': 11,
    'available': true,
    'city': 'T Nagar',
    'latitude': 13.0422,
    'longitude': 80.2299,
  },
  {
    'id': 'demo_mambalam_1',
    'name': 'Sanjay',
    'bloodGroup': 'B+',
    'donationCount': 7,
    'available': true,
    'city': 'West Mambalam',
    'latitude': 13.0382,
    'longitude': 80.2209,
  },
  {
    'id': 'demo_mambalam_2',
    'name': 'Swetha',
    'bloodGroup': 'O+',
    'donationCount': 13,
    'available': true,
    'city': 'West Mambalam',
    'latitude': 13.0357,
    'longitude': 80.2218,
  },
  {
    'id': 'demo_mambalam_3',
    'name': 'Vijay',
    'bloodGroup': 'A+',
    'donationCount': 8,
    'available': true,
    'city': 'West Mambalam',
    'latitude': 13.0328,
    'longitude': 80.2175,
  },
  {
    'id': 'demo_adyar_1',
    'name': 'Naveen',
    'bloodGroup': 'O+',
    'donationCount': 15,
    'available': true,
    'city': 'Adyar',
    'latitude': 13.0067,
    'longitude': 80.2570,
  },
  {
    'id': 'demo_adyar_2',
    'name': 'Keerthi',
    'bloodGroup': 'A+',
    'donationCount': 9,
    'available': true,
    'city': 'Adyar',
    'latitude': 13.0012,
    'longitude': 80.2564,
  },
  {
    'id': 'demo_adyar_3',
    'name': 'Mohan',
    'bloodGroup': 'B+',
    'donationCount': 8,
    'available': true,
    'city': 'Adyar',
    'latitude': 13.0114,
    'longitude': 80.2551,
  },
  {
    'id': 'demo_velachery_1',
    'name': 'Rohit',
    'bloodGroup': 'O+',
    'donationCount': 10,
    'available': true,
    'city': 'Velachery',
    'latitude': 12.9815,
    'longitude': 80.2180,
  },
  {
    'id': 'demo_velachery_2',
    'name': 'Lakshmi',
    'bloodGroup': 'AB+',
    'donationCount': 6,
    'available': true,
    'city': 'Velachery',
    'latitude': 12.9750,
    'longitude': 80.2210,
  },
  {
    'id': 'demo_velachery_3',
    'name': 'Anitha',
    'bloodGroup': 'B+',
    'donationCount': 11,
    'available': true,
    'city': 'Velachery',
    'latitude': 12.9860,
    'longitude': 80.2140,
  },
  {
    'id': 'demo_porur_1',
    'name': 'Adithya',
    'bloodGroup': 'A+',
    'donationCount': 7,
    'available': true,
    'city': 'Porur',
    'latitude': 13.0382,
    'longitude': 80.1565,
  },
  {
    'id': 'demo_ambattur_1',
    'name': 'Suresh',
    'bloodGroup': 'O+',
    'donationCount': 9,
    'available': true,
    'city': 'Ambattur',
    'latitude': 13.1143,
    'longitude': 80.1548,
  },
  {
    'id': 'demo_sholinganallur_1',
    'name': 'Harini',
    'bloodGroup': 'B+',
    'donationCount': 6,
    'available': true,
    'city': 'Sholinganallur',
    'latitude': 12.9010,
    'longitude': 80.2279,
  },
  {
    'id': 'demo_nungambakkam_1',
    'name': 'Vimal',
    'bloodGroup': 'O-',
    'donationCount': 5,
    'available': true,
    'city': 'Nungambakkam',
    'latitude': 13.0569,
    'longitude': 80.2425,
  },
  {
    'id': 'demo_kilpauk_1',
    'name': 'Asha',
    'bloodGroup': 'AB+',
    'donationCount': 6,
    'available': true,
    'city': 'Kilpauk',
    'latitude': 13.0780,
    'longitude': 80.2430,
  },
];

// Sample donor profiles for app demonstration/testing only. Names and generated
// locations are illustrative, not verified registered donors. Do not use these
// sample profiles for real-world blood requests.
List<Map<String, dynamic>> buildNearbyDemoDonorData({
  required double? originLatitude,
  required double? originLongitude,
  required String requestedArea,
}) {
  final baseLat = originLatitude ?? 13.0827; // Chennai fallback for demo mode.
  final baseLon = originLongitude ?? 80.2707;
  final area =
      requestedArea.trim().isNotEmpty &&
          requestedArea.trim().toLowerCase() != 'all areas'
      ? requestedArea.trim()
      : 'Nearby Area';
  const names = [
    'Arjun Kumar',
    'Meena R',
    'Karthik S',
    'Priya M',
    'Vignesh K',
    'Divya R',
    'Sanjay P',
    'Kavitha S',
    'Rahul N',
    'Nithya V',
    'Praveen M',
    'Anitha K',
    'Suresh R',
    'Deepa P',
    'Hari S',
    'Keerthana M',
    'Dinesh K',
    'Lavanya R',
    'Manoj V',
    'Swetha N',
    'Ashwin P',
    'Revathi S',
    'Gokul R',
    'Janani K',
    'Bala M',
    'Monisha V',
    'Surya K',
    'Ramya S',
    'Naveen R',
    'Aishwarya P',
    'Madhan S',
    'Sandhya K',
    'Vijay M',
    'Harini R',
    'Sathish P',
    'Abinaya S',
    'Ramesh K',
    'Pavithra M',
    'Ajay R',
    'Sangeetha V',
    'Prakash S',
    'Indhu K',
    'Kiran M',
    'Yamuna R',
    'Dhanush P',
    'Shalini S',
    'Bharath K',
    'Nandhini M',
    'Mohan R',
    'Kowsalya P',
    'Rohit S',
    'Thenmozhi K',
    'Nithish M',
    'Uma R',
    'Saravanan P',
    'Mahalakshmi S',
    'Vasanth K',
    'Dharani M',
    'Lokesh R',
    'Abirami P',
    'Siva S',
    'Preethi K',
    'Elango M',
    'Gayathri R',
    'Kishore P',
    'Bhavani S',
    'Aravind K',
    'Malathi M',
    'Ranjith R',
    'Sowmya P',
    'Muralidhar S',
    'Akila K',
  ];
  const groups = ['O+', 'A+', 'B+', 'O-', 'AB+', 'A-', 'B-', 'AB-'];
  final result = <Map<String, dynamic>>[];
  final latitudeScale = 111.0;
  final longitudeScale =
      111.0 * (math.cos(baseLat * math.pi / 180).abs().clamp(0.1, 1.0));

  for (var i = 0; i < names.length; i++) {
    // 24 within 5 km, 24 between 5 and 10 km, and 24 between 10 and 25 km.
    final double distanceKm;
    if (i < 24) {
      distanceKm = 0.4 + (i * 0.18); // 0.4–4.54 km
    } else if (i < 48) {
      distanceKm = 5.2 + ((i - 24) * 0.19); // 5.2–9.57 km
    } else {
      distanceKm = 10.5 + ((i - 48) * 0.58); // 10.5–23.84 km
    }
    final angle = i * 137.5 * math.pi / 180;
    final northKm = distanceKm * math.cos(angle);
    final eastKm = distanceKm * math.sin(angle);
    result.add({
      'id': 'demo_nearby_${i + 1}',
      'name': names[i],
      'bloodGroup': groups[i % groups.length],
      'donationCount': 3 + ((i * 7) % 15),
      'available': true,
      'city': area,
      'latitude': baseLat + northKm / latitudeScale,
      'longitude': baseLon + eastKm / longitudeScale,
    });
  }
  return result;
}

Donor _demoDonor(Map<String, dynamic> d) {
  return Donor(
    id: d['id']?.toString(),
    name: d['name']?.toString() ?? 'Demo Donor',
    bloodGroup: d['bloodGroup']?.toString() ?? 'O+',
    donationCount: (d['donationCount'] as num?)?.toInt() ?? 0,
    available: d['available'] != false,
    latitude: (d['latitude'] as num?)?.toDouble() ?? 0,
    longitude: (d['longitude'] as num?)?.toDouble() ?? 0,
    city: d['city']?.toString() ?? '',
  );
}

double donorDistanceKm(Donor donor, double? latitude, double? longitude) {
  if (latitude == null ||
      longitude == null ||
      donor.latitude == 0 ||
      donor.longitude == 0) {
    return double.infinity;
  }
  return Geolocator.distanceBetween(
        latitude,
        longitude,
        donor.latitude,
        donor.longitude,
      ) /
      1000.0;
}

Future<Position?> getDeviceLocation() async {
  final serviceEnabled = await Geolocator.isLocationServiceEnabled();
  if (!serviceEnabled) return null;

  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }
  if (permission == LocationPermission.denied ||
      permission == LocationPermission.deniedForever) {
    return null;
  }

  return Geolocator.getCurrentPosition(
    locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
  );
}

Future<Map<String, dynamic>> getRoleProfile(String role) async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return {};
  final doc = await FirebaseFirestore.instance
      .collection('users')
      .doc(user.uid)
      .get();
  final data = doc.data() ?? {};
  final profiles = data['roleProfiles'];
  if (profiles is Map && profiles[role] is Map) {
    return Map<String, dynamic>.from(profiles[role] as Map);
  }
  return {};
}

bool _areaMatches(String donorArea, String requestedArea) {
  final donor = donorArea.trim().toLowerCase();
  final requested = requestedArea.trim().toLowerCase();
  if (requested.isEmpty || requested == 'all areas') return true;
  if (donor.isEmpty) return false;

  // Match normalized area names without requiring an exact whole-address match.
  final normalize = (String value) => value
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim()
      .replaceAll(RegExp(r'\\s+'), ' ');
  final normalizedDonor = normalize(donor);
  final normalizedRequested = normalize(requested);
  return normalizedDonor == normalizedRequested ||
      normalizedDonor.contains(normalizedRequested) ||
      normalizedRequested.contains(normalizedDonor);
}

Future<List<Donor>> fetchPriorityDonors({
  required String bloodGroup,
  String city = '',
  double radiusKm = 10,
  double? originLatitude,
  double? originLongitude,
}) async {
  final user = FirebaseAuth.instance.currentUser;
  final snapshot = await FirebaseFirestore.instance.collection('users').get();
  final donors = <Donor>[];

  final targetGroup = bloodGroup.trim().toUpperCase();
  final requestedArea = city.trim().toLowerCase();

  for (final doc in snapshot.docs) {
    if (user != null && doc.id == user.uid) continue;

    final userData = doc.data();
    final rawProfiles = userData['roleProfiles'];
    // Older accounts may store the role key in lowercase. Accept both forms.
    final rawDonor = rawProfiles is Map
        ? (rawProfiles['Donor'] ?? rawProfiles['donor'])
        : null;
    // Also support accounts whose donor fields are stored at the user-document
    // level instead of inside roleProfiles.
    final profileSource = rawDonor is Map
        ? rawDonor
        : ((userData['role']?.toString().toLowerCase() == 'donor' ||
                  userData['activeRole']?.toString().toLowerCase() == 'donor')
              ? userData
              : null);
    if (profileSource is! Map) continue;

    final profile = Map<String, dynamic>.from(profileSource);
    final donor = Donor.fromRoleProfile(doc, profile);
    // Profiles created by older app versions may save the selected area under
    // city, area, locality, neighbourhood, or address. Normalize all variants.
    final donorGroup = donor.bloodGroup.trim().toUpperCase();
    final donorCity =
        [
              profile['city'],
              profile['area'],
              profile['locality'],
              profile['neighbourhood'],
              profile['neighborhood'],
              profile['address'],
              userData['city'],
              userData['area'],
              userData['locality'],
              userData['address'],
            ]
            .where((value) => value != null)
            .map((value) => value.toString().trim().toLowerCase())
            .where((value) => value.isNotEmpty)
            .join(' | ');

    if (!donor.available) continue;
    if (targetGroup != 'ALL' && !canDonorDonateTo(donorGroup, targetGroup))
      continue;

    // Area is a hard filter when an area is selected.
    if (requestedArea.isNotEmpty &&
        requestedArea != 'all areas' &&
        !_areaMatches(donorCity, requestedArea)) {
      continue;
    }

    // Distance is a hard filter. No donor outside the selected radius is shown.
    if (originLatitude != null && originLongitude != null) {
      final distance = donorDistanceKm(donor, originLatitude, originLongitude);
      if (distance > radiusKm) continue;
    }

    donors.add(donor);
  }

  final currentProfile = user == null
      ? <String, dynamic>{}
      : await getRoleProfile('Donor');
  final currentDonorName =
      currentProfile['name']?.toString().trim().toLowerCase() ?? '';

  for (final data in buildNearbyDemoDonorData(
    originLatitude: originLatitude,
    originLongitude: originLongitude,
    requestedArea: requestedArea,
  )) {
    final donor = _demoDonor(data);
    if (user != null && donor.id == user.uid) continue;
    if (currentDonorName.isNotEmpty &&
        donor.name.trim().toLowerCase() == currentDonorName) {
      continue;
    }
    if (!donor.available) continue;
    if (targetGroup != 'ALL' &&
        !canDonorDonateTo(donor.bloodGroup.trim().toUpperCase(), targetGroup)) {
      continue;
    }

    final donorCity = data['city']?.toString().trim().toLowerCase() ?? '';
    if (requestedArea.isNotEmpty &&
        requestedArea != 'all areas' &&
        !_areaMatches(donorCity, requestedArea)) {
      continue;
    }

    if (originLatitude != null && originLongitude != null) {
      final distance = donorDistanceKm(donor, originLatitude, originLongitude);
      if (distance > radiusKm) continue;
    }

    if (!donors.any((d) => d.id == donor.id)) donors.add(donor);
  }

  donors.sort((a, b) {
    // Priority ranking: exact blood-group match first, then experienced donors,
    // then the nearest donor as a tie-breaker.
    final aExact =
        targetGroup != 'ALL' && a.bloodGroup.trim().toUpperCase() == targetGroup
        ? 1
        : 0;
    final bExact =
        targetGroup != 'ALL' && b.bloodGroup.trim().toUpperCase() == targetGroup
        ? 1
        : 0;
    final exactCompare = bExact.compareTo(aExact);
    if (exactCompare != 0) return exactCompare;

    final donationCompare = b.donationCount.compareTo(a.donationCount);
    if (donationCompare != 0) return donationCompare;

    final da = donorDistanceKm(a, originLatitude, originLongitude);
    final db = donorDistanceKm(b, originLatitude, originLongitude);
    return da.compareTo(db);
  });

  return donors;
}

Future<void> createLifeLinkNotification({
  required String userId,
  required String title,
  required String message,
  String? requestId,
  String? senderId,
  String? type,
  String? bloodGroup,
}) async {
  await FirebaseFirestore.instance.collection('notifications').add({
    'userId': userId,
    'senderId': senderId ?? FirebaseAuth.instance.currentUser?.uid,
    'requestId': requestId,
    'type': type ?? 'general',
    'bloodGroup': bloodGroup,
    'title': title,
    'message': message,
    'read': false,
    'createdAt': FieldValue.serverTimestamp(),
  });
}

Future<void> notifyMatchingDonors({
  required String requestId,
  required String bloodGroup,
}) async {
  final current = FirebaseAuth.instance.currentUser;
  if (current == null) return;

  try {
    final snapshot = await FirebaseFirestore.instance.collection('users').get();
    final batch = FirebaseFirestore.instance.batch();

    for (final doc in snapshot.docs) {
      if (doc.id == current.uid) continue;
      final userData = doc.data();
      final profiles = userData['roleProfiles'];
      final rawDonor = profiles is Map ? profiles['Donor'] : null;
      final donor = rawDonor is Map
          ? Map<String, dynamic>.from(rawDonor)
          : <String, dynamic>{};
      if (donor['available'] == false) continue;
      final donorGroup =
          (donor['bloodGroup'] ??
                  donor['blood_group'] ??
                  userData['bloodGroup'] ??
                  userData['blood_group'])
              ?.toString()
              .trim()
              .toUpperCase() ??
          '';
      if (!canDonorDonateTo(donorGroup, bloodGroup)) continue;

      final ref = FirebaseFirestore.instance.collection('notifications').doc();
      batch.set(ref, {
        'userId': doc.id,
        'senderId': current.uid,
        'requestId': requestId,
        'type': 'blood_request',
        'bloodGroup': bloodGroup,
        'title': 'New blood request',
        'message':
            'A $bloodGroup blood request is waiting for an eligible donor.',
        'read': false,
        'createdAt': FieldValue.serverTimestamp(),
      });
    }
    await batch.commit();
  } catch (_) {
    // The blood request itself remains valid if notification creation is
    // rejected by a stricter existing Firebase configuration.
  }
}

Future<List<Donor>> fetchCompatibleDonors(String bloodGroup) async {
  return fetchPriorityDonors(bloodGroup: bloodGroup, radiusKm: 20);
}

Future<List<Donor>> fetchDonorsForBloodGroup(String bloodGroup) async {
  return fetchPriorityDonors(bloodGroup: bloodGroup, radiusKm: 20);
}

// ============================================================
// BLOOD COMPATIBILITY + PRIORITY
// ============================================================

bool canDonorDonateTo(String donorGroup, String recipientGroup) {
  const compatibility = {
    'O-': ['O-', 'O+', 'A-', 'A+', 'B-', 'B+', 'AB-', 'AB+'],
    'O+': ['O+', 'A+', 'B+', 'AB+'],
    'A-': ['A-', 'A+', 'AB-', 'AB+'],
    'A+': ['A+', 'AB+'],
    'B-': ['B-', 'B+', 'AB-', 'AB+'],
    'B+': ['B+', 'AB+'],
    'AB-': ['AB-', 'AB+'],
    'AB+': ['AB+'],
  };

  final donor = donorGroup.trim().toUpperCase();
  final recipient = recipientGroup.trim().toUpperCase();
  return compatibility[donor]?.contains(recipient) ?? false;
}

// ============================================================
// APP + AUTHENTICATION FLOW
// ============================================================

// ============================================================
// LIFELINK UI DESIGN SYSTEM
// Modern healthcare palette: teal + deep navy instead of the
// conventional blood-bank red. Firebase/data logic is unchanged.
// ============================================================

class AppColors {
  // LifeLink soft-pink and red visual system, matching the selected reference.
  static const Color primary = Color(0xFFD9364F);
  static const Color primaryDark = Color(0xFFAA2038);
  static const Color accent = Color(0xFFEF5368);
  static const Color navy = Color(0xFF632D3A);
  static const Color background = Color(0xFFFFF6F7);
  static const Color surface = Colors.white;
  static const Color softTeal = Color(0xFFFFE5EA);
  static const Color softBlue = Color(0xFFFFEEF1);
  static const Color border = Color(0xFFF3D5DC);
  static const Color text = Color(0xFF39232A);
  static const Color mutedText = Color(0xFF806A71);
  static const Color success = Color(0xFF21845A);
  static const Color warning = Color(0xFFB86A13);
  static const Color danger = Color(0xFFD9364F);
}

Widget llSectionTitle(String title, {String? action, VoidCallback? onAction}) {
  return Row(
    children: [
      Expanded(
        child: Text(
          title,
          style: const TextStyle(
            color: AppColors.navy,
            fontSize: 18,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      if (action != null)
        TextButton(
          onPressed: onAction,
          child: Text(
            action,
            style: const TextStyle(
              color: AppColors.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
    ],
  );
}

Widget llStatusChip(String status) {
  final normalized = status.toLowerCase();
  Color color;
  IconData icon;
  if (normalized.contains('emergency')) {
    color = AppColors.danger;
    icon = Icons.priority_high_rounded;
  } else if (normalized.contains('fulfilled') ||
      normalized.contains('completed') ||
      normalized.contains('verified')) {
    color = AppColors.success;
    icon = Icons.check_circle_outline;
  } else if (normalized.contains('progress') ||
      normalized.contains('accepted')) {
    color = const Color(0xFF2563EB);
    icon = Icons.sync_outlined;
  } else if (normalized.contains('cancel')) {
    color = AppColors.mutedText;
    icon = Icons.cancel_outlined;
  } else if (normalized.contains('priority')) {
    color = AppColors.primary;
    icon = Icons.star_outline;
  } else {
    color = AppColors.warning;
    icon = Icons.schedule_outlined;
  }
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .10),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(
          status,
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );
}

class RoleBottomNav extends StatelessWidget {
  final String role;
  final int currentIndex;

  const RoleBottomNav({
    super.key,
    required this.role,
    required this.currentIndex,
  });

  List<NavigationDestination> get destinations {
    switch (role) {
      case 'Donor':
        return const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.assignment_outlined),
            selectedIcon: Icon(Icons.assignment),
            label: 'Requests',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Profile',
          ),
        ];
      case 'Hospital':
        return const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.assignment_outlined),
            selectedIcon: Icon(Icons.assignment),
            label: 'Requests',
          ),
          NavigationDestination(
            icon: Icon(Icons.people_outline),
            selectedIcon: Icon(Icons.people),
            label: 'Donors',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Profile',
          ),
        ];
      case 'Blood Bank':
        return const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.inventory_2_outlined),
            selectedIcon: Icon(Icons.inventory_2),
            label: 'Inventory',
          ),
          NavigationDestination(
            icon: Icon(Icons.assignment_outlined),
            selectedIcon: Icon(Icons.assignment),
            label: 'Requests',
          ),
          NavigationDestination(
            icon: Icon(Icons.people_outline),
            selectedIcon: Icon(Icons.people),
            label: 'Donors',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Profile',
          ),
        ];
      default:
        return const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.assignment_outlined),
            selectedIcon: Icon(Icons.assignment),
            label: 'Requests',
          ),
          NavigationDestination(
            icon: Icon(Icons.people_outline),
            selectedIcon: Icon(Icons.people),
            label: 'Donors',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Profile',
          ),
        ];
    }
  }

  Widget _wrapTab(String role, int index, Widget page) {
    return RoleTabBackScope(role: role, currentIndex: index, child: page);
  }

  void openDestination(BuildContext context, int index) {
    if (index == currentIndex) return;

    late final Widget page;

    switch (role) {
      case 'Donor':
        page = [
          const DonorPage(),
          const BloodRequestsListPage(scope: 'compatible'),
          const ProfilePage(role: 'Donor'),
        ][index];
        break;
      case 'Hospital':
        page = [
          const HospitalDashboardPage(),
          const HospitalPage(currentIndex: 1),
          const NearbyDonorsPage(role: 'Hospital'),
          const ProfilePage(role: 'Hospital'),
        ][index];
        break;
      case 'Blood Bank':
        page = [
          const BloodBankPage(),
          const BloodBankPage(currentIndex: 1),
          const BloodRequestsListPage(scope: 'all'),
          const NearbyDonorsPage(role: 'Blood Bank'),
          const ProfilePage(role: 'Blood Bank'),
        ][index];
        break;
      default:
        page = [
          const PatientDashboardPage(),
          const PatientPage(),
          const NearbyDonorsPage(role: 'Patient'),
          const ProfilePage(role: 'Patient'),
        ][index];
    }

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => _wrapTab(role, index, page)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return NavigationBar(
      selectedIndex: currentIndex,
      height: 72,
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF21171A)
          : Colors.white,
      indicatorColor: AppColors.softTeal,
      elevation: 3,
      onDestinationSelected: (index) => openDestination(context, index),
      destinations: destinations,
    );
  }
}

class RoleTabBackScope extends StatelessWidget {
  final String role;
  final int currentIndex;
  final Widget child;

  const RoleTabBackScope({
    super.key,
    required this.role,
    required this.currentIndex,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        // If this tab was opened from another screen, use the normal
        // Android back behavior.
        if (Navigator.of(context).canPop()) {
          return true;
        }

        // A non-home bottom-tab is a top-level page. Pressing the
        // phone's back triangle takes the user back to that role's Home.
        if (currentIndex != 0) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => RoleHomePage(role: role)),
          );
        }

        // Never allow the Android back button to terminate LifeLink
        // from a role dashboard.
        return false;
      },
      child: child,
    );
  }
}

class BloodRequestsListPage extends StatefulWidget {
  final String scope;
  const BloodRequestsListPage({super.key, required this.scope});

  @override
  State<BloodRequestsListPage> createState() => _BloodRequestsListPageState();
}

class _BloodRequestsListPageState extends State<BloodRequestsListPage> {
  String? donorBloodGroup;
  bool loadingDonorGroup = false;

  @override
  void initState() {
    super.initState();
    if (widget.scope == 'compatible') _loadDonorBloodGroup();
  }

  Future<void> _loadDonorBloodGroup() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    setState(() => loadingDonorGroup = true);
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      final data = doc.data() ?? {};
      final profiles = data['roleProfiles'];
      final donorProfile = profiles is Map ? profiles['Donor'] : null;
      if (!mounted) return;
      setState(() {
        final profileGroup = donorProfile is Map
            ? (donorProfile['bloodGroup'] ?? donorProfile['blood_group'])
            : null;
        final rootGroup = data['bloodGroup'] ?? data['blood_group'];
        final resolvedGroup = (profileGroup ?? rootGroup)?.toString().trim();
        donorBloodGroup = (resolvedGroup == null || resolvedGroup.isEmpty)
            ? null
            : resolvedGroup.toUpperCase();
        loadingDonorGroup = false;
      });
    } catch (_) {
      if (mounted) setState(() => loadingDonorGroup = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    if (widget.scope == 'compatible' && loadingDonorGroup) {
      return Scaffold(
        appBar: AppBar(title: const Text('Blood Requests')),
        body: const Center(
          child: CircularProgressIndicator(color: AppColors.primary),
        ),
      );
    }

    Query<Map<String, dynamic>> query = FirebaseFirestore.instance.collection(
      'blood_requests',
    );

    // Listen to the collection and filter locally so older requests that only
    // have patientId (or only createdBy) are still visible to their owner.

    return Scaffold(
      appBar: AppBar(title: const Text('Blood Requests')),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: query.snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(color: AppColors.primary),
            );
          }
          if (snapshot.hasError) {
            return _EmptyFeatureState(
              icon: Icons.error_outline,
              title: 'Unable to load requests',
              message: snapshot.error.toString(),
            );
          }

          var requests = (snapshot.data?.docs ?? [])
              .map(BloodRequest.fromDoc)
              .toList();

          if (widget.scope == 'currentUser' && user != null) {
            requests = requests
                .where(
                  (request) =>
                      request.createdBy == user.uid ||
                      request.patientId == user.uid,
                )
                .toList();
          }

          if (widget.scope == 'compatible') {
            final group = donorBloodGroup?.trim().toUpperCase() ?? '';
            requests = requests.where((request) {
              final isOwn =
                  user != null &&
                  (request.createdBy == user.uid ||
                      request.patientId == user.uid);
              return !isOwn &&
                  request.status.trim().toLowerCase() == 'pending' &&
                  group.isNotEmpty &&
                  canDonorDonateTo(
                    group,
                    request.bloodGroup.trim().toUpperCase(),
                  );
            }).toList();
          }

          if (requests.isEmpty) {
            return _EmptyFeatureState(
              icon: Icons.assignment_outlined,
              title: widget.scope == 'compatible'
                  ? 'No matching blood requests'
                  : 'No blood requests',
              message: widget.scope == 'compatible'
                  ? (donorBloodGroup == null || donorBloodGroup!.isEmpty
                        ? 'Set your blood group in your donor profile to receive matching requests.'
                        : 'Requests for your blood group (${donorBloodGroup!}) will appear here.')
                  : 'Real requests from Firestore will appear here.',
            );
          }

          requests.sort(
            (a, b) => (b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0))
                .compareTo(
                  a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0),
                ),
          );

          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: requests.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (_, index) {
              final r = requests[index];
              return Card(
                child: InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: () {
                    activeBloodRequest = r;
                    activeBloodRequestId = r.id;
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => BloodRequestPage(
                          donorPosition: null,
                          hospitalDistance: null,
                          viewerRole: widget.scope == 'compatible'
                              ? 'Donor'
                              : (widget.scope == 'currentUser'
                                    ? 'Patient'
                                    : 'Blood Bank'),
                        ),
                      ),
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(15),
                    child: Row(
                      children: [
                        Container(
                          width: 46,
                          height: 46,
                          decoration: BoxDecoration(
                            color: r.emergency
                                ? AppColors.danger.withValues(alpha: .10)
                                : AppColors.softTeal,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Icon(
                            r.emergency
                                ? Icons.priority_high_rounded
                                : Icons.bloodtype_outlined,
                            color: r.emergency
                                ? AppColors.danger
                                : AppColors.primary,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${r.bloodGroup} · ${r.units} unit${r.units == 1 ? '' : 's'}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                r.hospital,
                                style: const TextStyle(
                                  color: AppColors.mutedText,
                                ),
                              ),
                              const SizedBox(height: 5),
                              llStatusChip(
                                r.emergency ? 'Emergency' : r.status,
                              ),
                            ],
                          ),
                        ),
                        const Icon(
                          Icons.chevron_right,
                          color: AppColors.mutedText,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// ============================================================
// ROLE HISTORY SHORTCUT
// History is intentionally not part of bottom navigation.
// ============================================================

class RoleHistoryPage extends StatelessWidget {
  final String role;

  const RoleHistoryPage({super.key, required this.role});

  @override
  Widget build(BuildContext context) {
    if (role == 'Donor') {
      return const DonationHistoryPage();
    }
    if (role == 'Patient' || role == 'Hospital') {
      return const BloodRequestsListPage(scope: 'currentUser');
    }
    return const BloodRequestsListPage(scope: 'all');
  }
}

class LifeLinkApp extends StatefulWidget {
  const LifeLinkApp({super.key});

  @override
  State<LifeLinkApp> createState() => _LifeLinkAppState();
}

class _LifeLinkAppState extends State<LifeLinkApp> {
  ThemeMode _themeMode = ThemeMode.light;

  void setDarkMode(bool enabled) {
    setState(() {
      _themeMode = enabled ? ThemeMode.dark : ThemeMode.light;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'LifeLink',

      // LIGHT THEME
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        colorScheme:
            ColorScheme.fromSeed(
              seedColor: AppColors.primary,
              brightness: Brightness.light,
            ).copyWith(
              primary: AppColors.primary,
              secondary: AppColors.accent,
              surface: AppColors.surface,
              onSurface: AppColors.text,
              error: AppColors.danger,
            ),

        scaffoldBackgroundColor: AppColors.background,
        fontFamily: 'Roboto',

        appBarTheme: const AppBarTheme(
          backgroundColor: AppColors.surface,
          foregroundColor: AppColors.text,
          elevation: 0,
          centerTitle: false,
          surfaceTintColor: Colors.transparent,
          titleTextStyle: TextStyle(
            color: AppColors.text,
            fontSize: 21,
            fontWeight: FontWeight.w700,
            fontFamily: 'Roboto',
          ),
          iconTheme: IconThemeData(color: AppColors.text),
        ),

        cardTheme: CardThemeData(
          color: AppColors.surface,
          elevation: 1,
          shadowColor: const Color(0x1AD9364F),
          margin: EdgeInsets.zero,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(22)),
            side: BorderSide(color: AppColors.border),
          ),
        ),

        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: AppColors.surface,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 15,
          ),
          hintStyle: const TextStyle(color: AppColors.mutedText),
          labelStyle: const TextStyle(color: AppColors.mutedText),
          prefixIconColor: AppColors.primary,
          suffixIconColor: AppColors.mutedText,

          border: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(14)),
            borderSide: BorderSide(color: AppColors.border),
          ),

          enabledBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(14)),
            borderSide: BorderSide(color: AppColors.border),
          ),

          focusedBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(14)),
            borderSide: BorderSide(color: AppColors.primary, width: 1.6),
          ),

          errorBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(14)),
            borderSide: BorderSide(color: AppColors.danger),
          ),

          focusedErrorBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(14)),
            borderSide: BorderSide(color: AppColors.danger, width: 1.6),
          ),
        ),

        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            elevation: 0,
            minimumSize: const Size(double.infinity, 52),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            textStyle: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),

        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.primary,
            side: const BorderSide(color: AppColors.primary),
            minimumSize: const Size(double.infinity, 50),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),

        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          elevation: 2,
        ),

        dividerTheme: const DividerThemeData(
          color: AppColors.border,
          thickness: 1,
          space: 1,
        ),

        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.navy,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),

      // DARK THEME
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,

        colorScheme:
            ColorScheme.fromSeed(
              seedColor: AppColors.primary,
              brightness: Brightness.dark,
            ).copyWith(
              primary: AppColors.accent,
              secondary: AppColors.primary,
              surface: const Color(0xFF261D21),
              onSurface: const Color(0xFFF8EDEF),
              onSurfaceVariant: const Color(0xFFD7BFC6),
              error: const Color(0xFFFF6B6B),
            ),

        scaffoldBackgroundColor: const Color(0xFF171316),
        fontFamily: 'Roboto',
        textTheme: const TextTheme(
          bodyLarge: TextStyle(color: Color(0xFFF8EDEF)),
          bodyMedium: TextStyle(color: Color(0xFFEADBE0)),
          bodySmall: TextStyle(color: Color(0xFFD7BFC6)),
          titleLarge: TextStyle(
            color: Color(0xFFFFF5F7),
            fontWeight: FontWeight.w700,
          ),
          titleMedium: TextStyle(
            color: Color(0xFFF8EDEF),
            fontWeight: FontWeight.w600,
          ),
          titleSmall: TextStyle(
            color: Color(0xFFE0C9D0),
            fontWeight: FontWeight.w600,
          ),
        ),

        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1E1E1E),
          foregroundColor: Colors.white,
          elevation: 0,
          centerTitle: false,
          surfaceTintColor: Colors.transparent,
          titleTextStyle: TextStyle(
            color: const Color(0xFFFFF5F7),
            fontSize: 21,
            fontWeight: FontWeight.w700,
            fontFamily: 'Roboto',
          ),
          iconTheme: IconThemeData(color: const Color(0xFFFFF5F7)),
        ),

        cardTheme: CardThemeData(
          color: const Color(0xFF261D21),
          elevation: 0,
          margin: EdgeInsets.zero,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: const BorderRadius.all(Radius.circular(18)),
            side: BorderSide(color: Colors.grey.shade800),
          ),
        ),

        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF21171A),

          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 15,
          ),

          hintStyle: const TextStyle(color: Colors.white60),

          labelStyle: const TextStyle(color: Colors.white70),

          prefixIconColor: AppColors.accent,
          suffixIconColor: Colors.white70,

          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: Colors.grey.shade700),
          ),

          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: Colors.grey.shade700),
          ),

          focusedBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(14)),
            borderSide: BorderSide(color: AppColors.accent, width: 1.6),
          ),

          errorBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(14)),
            borderSide: BorderSide(color: Color(0xFFFF6B6B)),
          ),

          focusedErrorBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(14)),
            borderSide: BorderSide(color: Color(0xFFFF6B6B), width: 1.6),
          ),
        ),

        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            elevation: 0,
            minimumSize: const Size(double.infinity, 52),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            textStyle: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),

        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.accent,
            side: const BorderSide(color: AppColors.accent),
            minimumSize: const Size(double.infinity, 50),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),

        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          elevation: 2,
        ),

        dividerTheme: DividerThemeData(
          color: Colors.grey.shade800,
          thickness: 1,
          space: 1,
        ),

        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xFF39262D),
          contentTextStyle: const TextStyle(color: Colors.white),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),

      // THIS CONTROLS WHICH THEME IS ACTIVE
      themeMode: _themeMode,

      home: const AuthGate(),
    );
  }
}

// ============================================================
// AUTH GATE
// ============================================================

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  Future<Widget> _nextPage(User user) async {
    await user.reload();
    final refreshedUser = FirebaseAuth.instance.currentUser;

    if (refreshedUser == null) {
      return const LoginPage();
    }

    if (!refreshedUser.emailVerified) {
      return const EmailVerificationPage();
    }

    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(refreshedUser.uid)
          .get();

      if (!doc.exists) {
        return const RoleSelectionPage();
      }

      final data = doc.data() ?? {};
      final role = data['role'] as String?;
      final profileCompleted = data['profileCompleted'] == true;

      if (role == null || role.isEmpty) {
        return const RoleSelectionPage();
      }

      if (!profileCompleted) {
        return ProfilePage(role: role);
      }

      return RoleHomePage(role: role);
    } catch (e) {
      return ErrorPage(message: 'Unable to load your profile.\n$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SplashPage();
        }

        final user = snapshot.data;

        if (user == null) {
          return const LoginPage();
        }

        return FutureBuilder<Widget>(
          future: _nextPage(user),
          builder: (context, pageSnapshot) {
            if (pageSnapshot.connectionState == ConnectionState.waiting) {
              return const SplashPage();
            }

            if (pageSnapshot.hasError) {
              return ErrorPage(message: pageSnapshot.error.toString());
            }

            return pageSnapshot.data ?? const LoginPage();
          },
        );
      },
    );
  }
}

// ============================================================
// SPLASH
// ============================================================

/// Friendly, asset-free cartoon decoration so the app works offline too.
class LifeLinkMascot extends StatelessWidget {
  final bool compact;
  final bool dark;

  const LifeLinkMascot({super.key, this.compact = false, this.dark = false});

  @override
  Widget build(BuildContext context) {
    final double size = compact ? 42 : 76;
    final Color tile = dark ? const Color(0xFF3B2029) : const Color(0xFFFFE7EC);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: tile,
        borderRadius: BorderRadius.circular(compact ? 14 : 24),
        border: Border.all(
          color: dark ? const Color(0xFF63313D) : AppColors.border,
        ),
      ),
      alignment: Alignment.center,
      child: Icon(
        Icons.bloodtype_rounded,
        color: AppColors.primary,
        size: compact ? 27 : 48,
      ),
    );
  }
}

class SplashPage extends StatelessWidget {
  const SplashPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFFFF0F3), Color(0xFFFFFAFB), Color(0xFFFFE7EC)],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 116,
                height: 116,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(38),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x22D9364F),
                      blurRadius: 28,
                      offset: Offset(0, 12),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.bloodtype_rounded,
                  color: AppColors.primary,
                  size: 76,
                ),
              ),
              const SizedBox(height: 22),
              const Text(
                'LifeLink',
                style: TextStyle(
                  color: AppColors.primaryDark,
                  fontSize: 38,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -.6,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Together, we save lives',
                style: TextStyle(
                  color: AppColors.mutedText,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 24),
              const SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// LOGIN
// ============================================================

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();

  bool loading = false;
  bool obscurePassword = true;

  Future<void> login() async {
    final email = emailController.text.trim();
    final password = passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      showMessage('Please enter your email and password.');
      return;
    }

    setState(() => loading = true);

    try {
      final credential = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      await credential.user?.reload();
      final user = FirebaseAuth.instance.currentUser;

      if (user != null && !user.emailVerified) {
        if (mounted) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => const EmailVerificationPage()),
          );
        }
        return;
      }

      if (mounted) {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => const AuthGate()),
          (route) => false,
        );
      }
    } on FirebaseAuthException catch (e) {
      showMessage(authErrorMessage(e.code));
    } catch (e) {
      showMessage('Login failed. Please try again.');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  String authErrorMessage(String code) {
    switch (code) {
      case 'invalid-credential':
      case 'wrong-password':
      case 'user-not-found':
        return 'Invalid email or password.';
      case 'invalid-email':
        return 'Please enter a valid email address.';
      case 'user-disabled':
        return 'This account has been disabled.';
      case 'too-many-requests':
        return 'Too many attempts. Please try again later.';
      default:
        return 'Login failed: $code';
    }
  }

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Welcome Back',
      subtitle: 'Login to continue to LifeLink',
      child: Column(
        children: [
          TextField(
            controller: emailController,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
              labelText: 'Email',
              hintText: 'Enter your email',
              prefixIcon: Icon(Icons.email_outlined, color: AppColors.primary),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: passwordController,
            obscureText: obscurePassword,
            decoration: InputDecoration(
              labelText: 'Password',
              prefixIcon: const Icon(
                Icons.lock_outline,
                color: AppColors.primary,
              ),
              suffixIcon: IconButton(
                onPressed: () {
                  setState(() => obscurePassword = !obscurePassword);
                },
                icon: Icon(
                  obscurePassword ? Icons.visibility : Icons.visibility_off,
                ),
              ),
            ),
          ),
          const SizedBox(height: 25),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: loading ? null : login,
              child: loading
                  ? const CircularProgressIndicator(color: Colors.white)
                  : const Text(
                      'Login',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 18),
          TextButton(
            onPressed: loading
                ? null
                : () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const RegisterPage()),
                    );
                  },
            child: const Text(
              "Don't have an account? Register",
              style: TextStyle(color: AppColors.primary),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// REGISTER
// ============================================================

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  final confirmPasswordController = TextEditingController();

  bool loading = false;
  bool obscurePassword = true;

  Future<void> register() async {
    final email = emailController.text.trim();
    final password = passwordController.text;
    final confirm = confirmPasswordController.text;

    if (email.isEmpty || password.isEmpty || confirm.isEmpty) {
      showMessage('Please fill in all fields.');
      return;
    }

    if (password.length < 6) {
      showMessage('Password must contain at least 6 characters.');
      return;
    }

    if (password != confirm) {
      showMessage('Passwords do not match.');
      return;
    }

    setState(() => loading = true);

    try {
      final credential = await FirebaseAuth.instance
          .createUserWithEmailAndPassword(email: email, password: password);

      await credential.user?.sendEmailVerification();

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const EmailVerificationPage()),
        );
      }
    } on FirebaseAuthException catch (e) {
      showMessage(registerErrorMessage(e.code));
    } catch (e) {
      showMessage('Registration failed. Please try again.');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  String registerErrorMessage(String code) {
    switch (code) {
      case 'email-already-in-use':
        return 'An account already exists with this email.';
      case 'invalid-email':
        return 'Please enter a valid email address.';
      case 'weak-password':
        return 'Password is too weak.';
      default:
        return 'Registration failed: $code';
    }
  }

  void showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    confirmPasswordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Create Account',
      subtitle: 'Register to get started with LifeLink',
      showBack: true,
      child: Column(
        children: [
          TextField(
            controller: emailController,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
              labelText: 'Email',
              hintText: 'Enter your email',
              prefixIcon: Icon(Icons.email_outlined, color: AppColors.primary),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: passwordController,
            obscureText: obscurePassword,
            decoration: InputDecoration(
              labelText: 'Password',
              prefixIcon: const Icon(
                Icons.lock_outline,
                color: AppColors.primary,
              ),
              suffixIcon: IconButton(
                onPressed: () {
                  setState(() => obscurePassword = !obscurePassword);
                },
                icon: Icon(
                  obscurePassword ? Icons.visibility : Icons.visibility_off,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: confirmPasswordController,
            obscureText: obscurePassword,
            decoration: const InputDecoration(
              labelText: 'Confirm Password',
              prefixIcon: Icon(Icons.lock_reset, color: AppColors.primary),
            ),
          ),
          const SizedBox(height: 25),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: loading ? null : register,
              child: loading
                  ? const CircularProgressIndicator(color: Colors.white)
                  : const Text(
                      'Create Account',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// EMAIL VERIFICATION
// ============================================================

class EmailVerificationPage extends StatefulWidget {
  const EmailVerificationPage({super.key});

  @override
  State<EmailVerificationPage> createState() => _EmailVerificationPageState();
}

class _EmailVerificationPageState extends State<EmailVerificationPage> {
  bool loading = false;
  bool sending = false;

  Future<void> checkVerification() async {
    setState(() => loading = true);

    try {
      final user = FirebaseAuth.instance.currentUser;

      if (user == null) {
        if (mounted) {
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(builder: (_) => const LoginPage()),
            (route) => false,
          );
        }
        return;
      }

      await user.reload();
      final refreshedUser = FirebaseAuth.instance.currentUser;

      if (refreshedUser?.emailVerified == true) {
        if (mounted) {
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(builder: (_) => const RoleSelectionPage()),
            (route) => false,
          );
        }
      } else {
        showMessage('Email is not verified yet. Please check your inbox.');
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> resendVerification() async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) return;

    setState(() => sending = true);

    try {
      await user.sendEmailVerification();
      showMessage('Verification email sent again.');
    } on FirebaseAuthException catch (e) {
      showMessage('Unable to send email: ${e.message ?? e.code}');
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  void showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> logout() async {
    await FirebaseAuth.instance.signOut();
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final email = FirebaseAuth.instance.currentUser?.email ?? '';

    return AuthScaffold(
      title: 'Verify Your Email',
      subtitle: 'A verification link was sent to\n$email',
      child: Column(
        children: [
          const Icon(Icons.mark_email_read, color: AppColors.primary, size: 80),
          const SizedBox(height: 20),
          const Text(
            'Please verify your email address before continuing.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16),
          ),
          const SizedBox(height: 25),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton.icon(
              onPressed: loading ? null : checkVerification,
              icon: loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(Icons.verified),
              label: const Text('I Have Verified My Email'),
            ),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: sending ? null : resendVerification,
            child: Text(
              sending ? 'Sending...' : 'Resend Verification Email',
              style: const TextStyle(color: AppColors.primary),
            ),
          ),
          TextButton(
            onPressed: logout,
            child: const Text('Use a Different Account'),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// ROLE SELECTION
// ============================================================

class RoleSelectionPage extends StatefulWidget {
  const RoleSelectionPage({super.key});

  @override
  State<RoleSelectionPage> createState() => _RoleSelectionPageState();
}

class _RoleSelectionPageState extends State<RoleSelectionPage> {
  bool saving = false;

  Future<void> selectRole(String role) async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const LoginPage()),
        (route) => false,
      );
      return;
    }

    setState(() => saving = true);

    try {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'uid': user.uid,
        'email': user.email,
        'role': role,
        'profileCompleted': false,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => ProfilePage(role: role)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Unable to save role: $e')));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Choose Your Role'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        automaticallyImplyLeading: false,
      ),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const SizedBox(height: 20),
              const Text(
                'How would you like to use LifeLink?',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              const Text(
                'Select your role. You can complete your profile next.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 30),
              roleCard(
                context,
                Icons.volunteer_activism,
                'Donor',
                'Donate blood and help save lives',
                AppColors.primary,
              ),
              roleCard(
                context,
                Icons.personal_injury,
                'Patient',
                'Request blood during emergencies',
                AppColors.primary,
              ),
              roleCard(
                context,
                Icons.local_hospital,
                'Hospital',
                'Manage blood requests',
                AppColors.primary,
              ),
              roleCard(
                context,
                Icons.bloodtype,
                'Blood Bank',
                'Manage blood inventory',
                AppColors.primary,
              ),
            ],
          ),
          if (saving)
            Container(
              color: Colors.black26,
              child: const Center(
                child: CircularProgressIndicator(color: AppColors.primary),
              ),
            ),
        ],
      ),
    );
  }

  Widget roleCard(
    BuildContext context,
    IconData icon,
    String title,
    String subtitle,
    Color color,
  ) {
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      elevation: 1,
      shadowColor: const Color(0x18D9364F),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: const BorderSide(color: AppColors.border),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 17,
          vertical: 12,
        ),
        leading: CircleAvatar(
          radius: 28,
          backgroundColor: color.withValues(alpha: 0.1),
          child: Icon(icon, color: color, size: 30),
        ),
        title: Text(
          title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.arrow_forward_ios),
        onTap: saving ? null : () => selectRole(title),
      ),
    );
  }
}

// ============================================================
// SWITCH ROLE PAGE
// ============================================================

class RoleSwitchPage extends StatefulWidget {
  final String currentRole;

  const RoleSwitchPage({super.key, required this.currentRole});

  @override
  State<RoleSwitchPage> createState() => _RoleSwitchPageState();
}

class _RoleSwitchPageState extends State<RoleSwitchPage> {
  bool saving = false;

  Future<void> switchRole(String role) async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const LoginPage()),
        (route) => false,
      );
      return;
    }

    setState(() => saving = true);

    try {
      if (!mounted) return;

      // Every role switch opens that role's own profile first. Existing
      // role data is loaded into the form, so the user can review or update
      // it before entering the role home page. Each role keeps its own data.
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => ProfilePage(role: role, isRoleSetup: true),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Unable to switch role. Check Firestore permissions: $e',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Switch Role'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const SizedBox(height: 15),
              const Icon(Icons.swap_horiz, color: AppColors.primary, size: 70),
              const SizedBox(height: 15),
              const Text(
                'Choose how you want to use LifeLink',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                'Current role: ${widget.currentRole}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey, fontSize: 15),
              ),
              const SizedBox(height: 30),
              roleSwitchCard(
                Icons.volunteer_activism,
                'Donor',
                'Donate blood and help save lives',
              ),
              roleSwitchCard(
                Icons.personal_injury,
                'Patient',
                'Request blood during emergencies',
              ),
              roleSwitchCard(
                Icons.local_hospital,
                'Hospital',
                'Manage blood requests',
              ),
              roleSwitchCard(
                Icons.bloodtype,
                'Blood Bank',
                'Manage blood inventory',
              ),
            ],
          ),
          if (saving)
            Container(
              color: Colors.black26,
              child: const Center(
                child: CircularProgressIndicator(color: AppColors.primary),
              ),
            ),
        ],
      ),
    );
  }

  Widget roleSwitchCard(IconData icon, String title, String subtitle) {
    final isCurrent = title == widget.currentRole;

    return Card(
      margin: const EdgeInsets.only(bottom: 15),
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: ListTile(
        contentPadding: const EdgeInsets.all(15),
        leading: CircleAvatar(
          radius: 28,
          backgroundColor: AppColors.primary.withValues(alpha: 0.1),
          child: Icon(icon, color: AppColors.primary, size: 30),
        ),
        title: Text(
          title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        subtitle: Text(isCurrent ? 'Current role' : subtitle),
        trailing: isCurrent
            ? const Icon(Icons.check_circle, color: Colors.green)
            : const Icon(Icons.arrow_forward_ios),
        onTap: saving ? null : () => switchRole(title),
      ),
    );
  }
}

// ============================================================
// PROFILE PAGE
// ============================================================

class ProfilePage extends StatefulWidget {
  final String role;
  final bool isRoleSetup;

  const ProfilePage({super.key, required this.role, this.isRoleSetup = false});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final nameController = TextEditingController();
  final phoneController = TextEditingController();
  final addressController = TextEditingController();
  final cityController = TextEditingController();
  final bloodGroupController = TextEditingController();
  final contactPersonController = TextEditingController();
  final registrationController = TextEditingController();

  bool saving = false;
  String bloodGroup = 'O+';

  bool get needsBloodGroup =>
      widget.role == 'Donor' || widget.role == 'Patient';

  bool get isOrganization =>
      widget.role == 'Hospital' || widget.role == 'Blood Bank';

  String get title {
    switch (widget.role) {
      case 'Donor':
        return 'Donor Profile';
      case 'Patient':
        return 'Patient Profile';
      case 'Hospital':
        return 'Hospital Profile';
      default:
        return 'Blood Bank Profile';
    }
  }

  String get nameLabel {
    return isOrganization ? 'Organization Name' : 'Full Name';
  }

  String get registrationLabel {
    return widget.role == 'Blood Bank'
        ? 'Blood Bank License / Registration Number'
        : 'Hospital Registration Number';
  }

  String get contactLabel {
    return widget.role == 'Blood Bank'
        ? 'Contact Person'
        : 'Contact Person / Administrator';
  }

  @override
  void initState() {
    super.initState();
    loadExistingProfile();
  }

  Future<void> loadExistingProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      // Store each role profile inside the user's own document. This avoids
      // depending on a separate roleProfiles subcollection whose Firestore
      // rules may not exist in the current project.
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();

      final userData = userDoc.data() ?? {};
      Map<String, dynamic> data = {};

      final allRoleProfiles = userData['roleProfiles'];
      if (allRoleProfiles is Map) {
        final roleData = allRoleProfiles[widget.role];
        if (roleData is Map) {
          data = Map<String, dynamic>.from(roleData);
        }
      }

      // Backward compatibility: if a role profile was previously saved in
      // the old subcollection, try to read it.
      if (data.isEmpty) {
        try {
          final roleDoc = await FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .collection('roleProfiles')
              .doc(widget.role)
              .get();
          data = roleDoc.data() ?? {};
        } catch (_) {
          // The current Firebase rules may not allow this subcollection.
        }
      }

      // Last fallback for older accounts that only have one flat profile.
      if (data.isEmpty && userData['role'] == widget.role) {
        data = userData;
      }

      if (!mounted) return;

      setState(() {
        nameController.text = data['name']?.toString() ?? '';
        phoneController.text = data['phone']?.toString() ?? '';
        addressController.text = data['address']?.toString() ?? '';
        cityController.text = data['city']?.toString() ?? '';
        bloodGroup = data['bloodGroup']?.toString() ?? 'O+';
        contactPersonController.text = data['contactPerson']?.toString() ?? '';
        registrationController.text =
            data['registrationNumber']?.toString() ?? '';
      });
    } catch (_) {}
  }

  Future<void> saveProfile() async {
    final name = nameController.text.trim();
    final phone = phoneController.text.trim();
    final address = addressController.text.trim();

    if (name.isEmpty || phone.isEmpty || address.isEmpty) {
      showMessage('Please fill in all required fields.');
      return;
    }

    if (needsBloodGroup && bloodGroup.isEmpty) {
      showMessage('Please select your blood group.');
      return;
    }

    if (isOrganization) {
      if (contactPersonController.text.trim().isEmpty ||
          registrationController.text.trim().isEmpty) {
        showMessage('Please enter the contact person and registration number.');
        return;
      }
    }

    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      showMessage('Please login again.');
      return;
    }

    setState(() => saving = true);

    try {
      final userRef = FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid);

      final roleData = <String, dynamic>{
        'uid': user.uid,
        'email': user.email,
        'role': widget.role,
        'name': name,
        'phone': phone,
        'address': address,
        'city': cityController.text.trim(),
        'bloodGroup': needsBloodGroup ? bloodGroup : null,
        'profileCompleted': true,
        if (isOrganization)
          'contactPerson': contactPersonController.text.trim(),
        if (isOrganization)
          'registrationNumber': registrationController.text.trim(),
        'updatedAt': FieldValue.serverTimestamp(),
      };

      // Keep donor-specific values inside the donor profile only.
      if (widget.role == 'Donor') {
        final currentUserDoc = await userRef.get();
        final currentData = currentUserDoc.data() ?? {};
        final allProfilesRaw = currentData['roleProfiles'];
        final existingProfiles = allProfilesRaw is Map
            ? Map<String, dynamic>.from(allProfilesRaw)
            : <String, dynamic>{};
        final existingDonorRaw = existingProfiles['Donor'];
        final existingDonor = existingDonorRaw is Map
            ? Map<String, dynamic>.from(existingDonorRaw)
            : <String, dynamic>{};
        roleData['available'] = existingDonor['available'] ?? true;
        roleData['donationCount'] = existingDonor['donationCount'] ?? 0;
      }

      // Save the role-specific profile in the user's document. Each role has
      // its own entry, so Patient data can never become Donor data.
      final currentUserDoc = await userRef.get();
      final currentData = currentUserDoc.data() ?? {};
      final allProfilesRaw = currentData['roleProfiles'];
      final allProfiles = allProfilesRaw is Map
          ? Map<String, dynamic>.from(allProfilesRaw)
          : <String, dynamic>{};
      allProfiles[widget.role] = roleData;

      await userRef.set({'roleProfiles': allProfiles}, SetOptions(merge: true));

      // Keep the existing flat user document compatible with the rest of
      // the current Firebase data model. Only the ACTIVE role is mirrored.
      final activeMirror = <String, dynamic>{
        'uid': user.uid,
        'email': user.email,
        'role': widget.role,
        'name': name,
        'phone': phone,
        'address': address,
        'bloodGroup': needsBloodGroup ? bloodGroup : null,
        'profileCompleted': true,
        if (isOrganization)
          'contactPerson': contactPersonController.text.trim(),
        if (isOrganization)
          'registrationNumber': registrationController.text.trim(),
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (widget.role == 'Donor') {
        activeMirror['available'] = roleData['available'];
        activeMirror['donationCount'] = roleData['donationCount'];
      }

      await userRef.set(activeMirror, SetOptions(merge: true));

      if (mounted) {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => RoleHomePage(role: widget.role)),
          (route) => false,
        );
      }
    } catch (e) {
      showMessage('Unable to save profile: $e');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  void showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    nameController.dispose();
    phoneController.dispose();
    addressController.dispose();
    cityController.dispose();
    bloodGroupController.dispose();
    contactPersonController.dispose();
    registrationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        automaticallyImplyLeading: !widget.isRoleSetup,
      ),
      body: Stack(
        children: [
          SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  isOrganization
                      ? (widget.role == 'Blood Bank'
                            ? Icons.bloodtype_outlined
                            : Icons.local_hospital_outlined)
                      : Icons.person_pin,
                  color: AppColors.primary,
                  size: 65,
                ),
                const SizedBox(height: 10),
                Text(
                  widget.isRoleSetup
                      ? 'Set up your ${widget.role} profile'
                      : 'Complete your profile',
                  style: const TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  isOrganization
                      ? 'Enter the details for this ${widget.role.toLowerCase()} account. These details are separate from your other LifeLink roles.'
                      : 'This information helps LifeLink provide the right services for your role.',
                  style: const TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 25),
                TextField(
                  controller: nameController,
                  decoration: InputDecoration(
                    labelText: nameLabel,
                    prefixIcon: Icon(
                      isOrganization
                          ? Icons.business_outlined
                          : Icons.person_outline,
                      color: AppColors.primary,
                    ),
                  ),
                ),
                const SizedBox(height: 15),
                if (isOrganization) ...[
                  TextField(
                    controller: contactPersonController,
                    decoration: InputDecoration(
                      labelText: contactLabel,
                      prefixIcon: const Icon(
                        Icons.badge_outlined,
                        color: AppColors.primary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 15),
                ],
                TextField(
                  controller: phoneController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Phone Number',
                    prefixIcon: Icon(
                      Icons.phone_outlined,
                      color: AppColors.primary,
                    ),
                  ),
                ),
                const SizedBox(height: 15),
                TextField(
                  controller: addressController,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Address / Location',
                    prefixIcon: Icon(
                      Icons.location_on_outlined,
                      color: AppColors.primary,
                    ),
                  ),
                ),
                const SizedBox(height: 15),
                TextField(
                  controller: cityController,
                  decoration: const InputDecoration(
                    labelText: 'City',
                    prefixIcon: Icon(
                      Icons.location_city_outlined,
                      color: AppColors.primary,
                    ),
                  ),
                ),
                if (isOrganization) ...[
                  const SizedBox(height: 15),
                  TextField(
                    controller: registrationController,
                    decoration: InputDecoration(
                      labelText: registrationLabel,
                      prefixIcon: const Icon(
                        Icons.verified_outlined,
                        color: AppColors.primary,
                      ),
                    ),
                  ),
                ],
                if (needsBloodGroup) ...[
                  const SizedBox(height: 15),
                  bloodGroupDropdown(bloodGroup, AppColors.primary, (value) {
                    if (value != null) {
                      setState(() => bloodGroup = value);
                    }
                  }),
                ],
                const SizedBox(height: 15),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: saving
                        ? null
                        : () async {
                            final position = await getDeviceLocation();
                            if (position == null) {
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Please enable location permission.',
                                    ),
                                  ),
                                );
                              }
                              return;
                            }
                            await updateRoleProfileFields(widget.role, {
                              'latitude': position.latitude,
                              'longitude': position.longitude,
                              'locationUpdatedAt': FieldValue.serverTimestamp(),
                            });
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Current location saved.'),
                                ),
                              );
                            }
                          },
                    icon: const Icon(Icons.my_location),
                    label: const Text('Use Current Location'),
                  ),
                ),
                const SizedBox(height: 25),
                SizedBox(
                  width: double.infinity,
                  height: 55,
                  child: ElevatedButton.icon(
                    onPressed: saving ? null : saveProfile,
                    icon: saving
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                        : const Icon(Icons.save_outlined),
                    label: Text(
                      saving ? 'Saving...' : 'Save & Continue',
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (saving)
            Container(
              color: Colors.black12,
              child: const Center(
                child: CircularProgressIndicator(color: AppColors.primary),
              ),
            ),
        ],
      ),
    );
  }
}

// ============================================================
// ROLE HOME ROUTER
// ============================================================

class RoleHomePage extends StatelessWidget {
  final String role;

  const RoleHomePage({super.key, required this.role});

  @override
  Widget build(BuildContext context) {
    switch (role) {
      case 'Donor':
        return DashboardBackScope(role: role, child: const DonorPage());
      case 'Patient':
        return DashboardBackScope(
          role: role,
          child: const PatientDashboardPage(),
        );
      case 'Hospital':
        return DashboardBackScope(
          role: role,
          child: const HospitalDashboardPage(),
        );
      case 'Blood Bank':
        return DashboardBackScope(role: role, child: const BloodBankPage());
      default:
        return const RoleSelectionPage();
    }
  }
}

// ============================================================
// AUTH UI HELPERS
// ============================================================

class AuthScaffold extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget child;
  final bool showBack;

  const AuthScaffold({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
    this.showBack = false,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = dark ? const Color(0xFF261D21) : Colors.white;
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: dark
                ? const [Color(0xFF171316), Color(0xFF21171A)]
                : const [
                    Color(0xFFFFF0F3),
                    Color(0xFFFFFAFB),
                    Color(0xFFFFE7EC),
                  ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(22),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 500),
                child: Column(
                  children: [
                    if (showBack)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.arrow_back_rounded),
                        ),
                      ),
                    Container(
                      width: 88,
                      height: 88,
                      decoration: BoxDecoration(
                        color: cardColor,
                        borderRadius: BorderRadius.circular(29),
                        boxShadow: dark
                            ? const []
                            : const [
                                BoxShadow(
                                  color: Color(0x1AD9364F),
                                  blurRadius: 22,
                                  offset: Offset(0, 8),
                                ),
                              ],
                      ),
                      child: const Icon(
                        Icons.bloodtype_rounded,
                        color: AppColors.primary,
                        size: 62,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'LifeLink',
                      style: TextStyle(
                        fontSize: 35,
                        fontWeight: FontWeight.w900,
                        color: AppColors.primary,
                        letterSpacing: -.5,
                      ),
                    ),
                    const SizedBox(height: 5),
                    const Text(
                      'Together, we save lives',
                      style: TextStyle(
                        color: AppColors.mutedText,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 10),
                    LifeLinkMascot(compact: true, dark: dark),
                    const SizedBox(height: 24),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(22),
                      decoration: BoxDecoration(
                        color: cardColor,
                        borderRadius: BorderRadius.circular(26),
                        border: Border.all(
                          color: dark
                              ? const Color(0xFF49333B)
                              : AppColors.border,
                        ),
                        boxShadow: dark
                            ? const []
                            : const [
                                BoxShadow(
                                  color: Color(0x12D9364F),
                                  blurRadius: 24,
                                  offset: Offset(0, 8),
                                ),
                              ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            title,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            subtitle,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: dark
                                      ? const Color(0xFFD7BFC6)
                                      : AppColors.mutedText,
                                ),
                          ),
                          const SizedBox(height: 26),
                          child,
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ErrorPage extends StatelessWidget {
  final String message;

  const ErrorPage({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(25),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.error_outline,
                color: AppColors.primary,
                size: 70,
              ),
              const SizedBox(height: 15),
              const Text(
                'Something went wrong',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () {
                  Navigator.pushAndRemoveUntil(
                    context,
                    MaterialPageRoute(builder: (_) => const LoginPage()),
                    (route) => false,
                  );
                },
                child: const Text('Back to Login'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// ACCOUNT MENU + DASHBOARD BACK BEHAVIOUR
// ============================================================

Future<void> logoutUser(BuildContext context) async {
  await FirebaseAuth.instance.signOut();

  if (!context.mounted) return;

  Navigator.pushAndRemoveUntil(
    context,
    MaterialPageRoute(builder: (_) => const LoginPage()),
    (route) => false,
  );
}

// ============================================================
// USER GREETING + ACCOUNT SUPPORT
// ============================================================

class RoleProfileLabel extends StatelessWidget {
  final String role;

  const RoleProfileLabel({super.key, required this.role});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text(
        '$role Profile',
        style: const TextStyle(
          color: AppColors.mutedText,
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class UserGreeting extends StatelessWidget {
  final String role;
  final String subtitle;

  const UserGreeting({super.key, required this.role, required this.subtitle});

  Future<String> _loadName() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return role;

    try {
      // Read the name from the profile belonging to the CURRENT role.
      // Do not use the flat users.name field here because that field is only
      // the active-role mirror and can otherwise show the previous role's name.
      final snapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      final data = snapshot.data() ?? {};

      final allRoleProfiles = data['roleProfiles'];
      if (allRoleProfiles is Map) {
        final roleData = allRoleProfiles[role];
        if (roleData is Map) {
          final storedName = roleData['name']?.toString().trim() ?? '';
          if (storedName.isNotEmpty) return storedName;
        }
      }

      // Backward compatibility for older accounts.
      try {
        final roleSnapshot = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .collection('roleProfiles')
            .doc(role)
            .get();
        final roleData = roleSnapshot.data();
        final storedName = roleData?['name']?.toString().trim() ?? '';
        if (storedName.isNotEmpty) return storedName;
      } catch (_) {}

      // Only use the flat name if this is actually the same active role.
      final activeRole = data['role']?.toString() ?? '';
      if (activeRole == role) {
        final legacyName = data['name']?.toString().trim() ?? '';
        if (legacyName.isNotEmpty) return legacyName;
      }
    } catch (_) {}

    final email = user.email ?? '';
    if (email.contains('@')) {
      final prefix = email.split('@').first.trim();
      if (prefix.isNotEmpty) return prefix;
    }

    return role;
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return FutureBuilder<String>(
      future: _loadName(),
      builder: (context, snapshot) {
        final name = snapshot.data ?? role;
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: 10),
          padding: const EdgeInsets.fromLTRB(18, 18, 10, 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: dark
                  ? const [Color(0xFF3A2029), Color(0xFF291B21)]
                  : const [Color(0xFFFFE4EA), Color(0xFFFFF4F6)],
            ),
            border: Border.all(
              color: dark ? const Color(0xFF63313D) : const Color(0xFFF4CDD6),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: dark
                            ? const Color(0xFF522631)
                            : Colors.white.withValues(alpha: 0.8),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        '$role community',
                        style: const TextStyle(
                          color: AppColors.primary,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Welcome $name 👋',
                      style: TextStyle(
                        color: dark ? const Color(0xFFFFE8ED) : AppColors.navy,
                        fontSize: 22,
                        height: 1.15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: dark
                            ? const Color(0xFFD8C2C8)
                            : AppColors.mutedText,
                        fontSize: 12.5,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              const LifeLinkMascot(compact: true),
            ],
          ),
        );
      },
    );
  }
}

class NotificationsPage extends StatelessWidget {
  const NotificationsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: user == null
          ? const Center(child: Text('Please login again.'))
          : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: FirebaseFirestore.instance
                  .collection('notifications')
                  .where('userId', isEqualTo: user.uid)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(color: AppColors.primary),
                  );
                }

                if (snapshot.hasError) {
                  return const _EmptyFeatureState(
                    icon: Icons.notifications_none,
                    title: 'No notifications',
                    message: 'New LifeLink notifications will appear here.',
                  );
                }

                final docs = snapshot.data?.docs ?? [];

                if (docs.isEmpty) {
                  return const _EmptyFeatureState(
                    icon: Icons.notifications_none,
                    title: 'No notifications',
                    message: 'New LifeLink notifications will appear here.',
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.all(18),
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final data = docs[index].data();
                    final title =
                        data['title']?.toString() ?? 'LifeLink notification';
                    final message = data['message']?.toString() ?? '';
                    final read = data['read'] == true;

                    return Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: read
                              ? Colors.grey.shade200
                              : AppColors.primary.withValues(alpha: 0.18),
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const CircleAvatar(
                            backgroundColor: AppColors.softTeal,
                            child: Icon(
                              Icons.notifications_none,
                              color: AppColors.primary,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  title,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                ),
                                if (message.isNotEmpty) ...[
                                  const SizedBox(height: 5),
                                  Text(
                                    message,
                                    style: const TextStyle(color: Colors.grey),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool notificationsEnabled = true;
  bool bloodRequestAlerts = true;
  bool donationReminders = true;
  bool nearbyRequests = true;
  bool darkMode = false;
  bool loading = true;
  bool saving = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted) setState(() => loading = false);
      return;
    }

    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();

      final data = snapshot.data();
      final settings = data?['settings'];
      if (settings is Map) {
        if (mounted) {
          setState(() {
            notificationsEnabled = settings['notificationsEnabled'] != false;
            bloodRequestAlerts = settings['bloodRequestAlerts'] != false;
            donationReminders = settings['donationReminders'] != false;
            nearbyRequests = settings['nearbyRequests'] != false;
            darkMode = settings['darkMode'] == true;
          });
        }
      }
    } catch (_) {
      // Keep the default settings if Firestore is unavailable.
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _saveSettings() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    setState(() => saving = true);

    try {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'settings': {
          'notificationsEnabled': notificationsEnabled,
          'bloodRequestAlerts': bloodRequestAlerts,
          'donationReminders': donationReminders,
          'nearbyRequests': nearbyRequests,
          'darkMode': darkMode,
        },
      }, SetOptions(merge: true));

      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Settings saved.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Unable to save settings: $e')));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  void _setNotifications(bool value) {
    setState(() {
      notificationsEnabled = value;
      if (!value) {
        bloodRequestAlerts = false;
        donationReminders = false;
        nearbyRequests = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        actions: [
          if (saving)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
        ],
      ),
      body: loading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.primary),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 30),
              children: [
                _settingsSection(
                  title: 'Notifications',
                  children: [
                    _switchTile(
                      icon: Icons.notifications_none,
                      title: 'Notifications',
                      subtitle: 'Enable LifeLink notifications',
                      value: notificationsEnabled,
                      onChanged: _setNotifications,
                    ),
                    _switchTile(
                      icon: Icons.bloodtype_outlined,
                      title: 'Blood request alerts',
                      subtitle: 'Receive alerts for compatible blood requests',
                      value: bloodRequestAlerts,
                      enabled: notificationsEnabled,
                      onChanged: (value) =>
                          setState(() => bloodRequestAlerts = value),
                    ),
                    _switchTile(
                      icon: Icons.event_available_outlined,
                      title: 'Donation reminders',
                      subtitle: 'Receive reminders related to blood donation',
                      value: donationReminders,
                      enabled: notificationsEnabled,
                      onChanged: (value) =>
                          setState(() => donationReminders = value),
                    ),
                    _switchTile(
                      icon: Icons.near_me_outlined,
                      title: 'Nearby requests',
                      subtitle: 'Notify me about nearby blood requests',
                      value: nearbyRequests,
                      enabled: notificationsEnabled,
                      onChanged: (value) =>
                          setState(() => nearbyRequests = value),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _settingsSection(
                  title: 'Appearance',
                  children: [
                    _switchTile(
                      icon: Icons.dark_mode_outlined,
                      title: 'Dark mode',
                      subtitle: 'Use a dark appearance',
                      value: darkMode,
                      onChanged: (value) {
                        setState(() {
                          darkMode = value;
                        });

                        final appState = context
                            .findAncestorStateOfType<_LifeLinkAppState>();

                        appState?.setDarkMode(value);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _settingsSection(
                  title: 'Account',
                  children: [
                    ListTile(
                      leading: const Icon(
                        Icons.lock_outline,
                        color: AppColors.primary,
                      ),
                      title: const Text('Change password'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _showChangePasswordDialog(context),
                    ),
                    ListTile(
                      leading: const Icon(
                        Icons.person_outline,
                        color: AppColors.primary,
                      ),
                      title: const Text('Edit profile'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () async {
                        final user = FirebaseAuth.instance.currentUser;
                        if (user == null) return;

                        String role = 'Donor';
                        try {
                          final snapshot = await FirebaseFirestore.instance
                              .collection('users')
                              .doc(user.uid)
                              .get();
                          role =
                              snapshot.data()?['role']?.toString() ?? 'Donor';
                        } catch (_) {}

                        if (!context.mounted) return;
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ProfilePage(role: role),
                          ),
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _settingsSection(
                  title: 'About',
                  children: [
                    ListTile(
                      leading: const Icon(
                        Icons.info_outline,
                        color: AppColors.primary,
                      ),
                      title: const Text('About LifeLink'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _showAboutDialog(context),
                    ),
                    const ListTile(
                      leading: Icon(
                        Icons.verified_user_outlined,
                        color: AppColors.primary,
                      ),
                      title: Text('Privacy Policy'),
                    ),
                    const ListTile(
                      leading: Icon(
                        Icons.description_outlined,
                        color: AppColors.primary,
                      ),
                      title: Text('Terms & Conditions'),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                SizedBox(
                  height: 48,
                  child: ElevatedButton(
                    onPressed: saving ? null : _saveSettings,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('Save Settings'),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _settingsSection({
    required String title,
    required List<Widget> children,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: isDark ? Border.all(color: Colors.grey.shade800) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 6),
            child: Text(
              title,
              style: TextStyle(
                color: isDark ? const Color(0xFFFF6B6B) : AppColors.primary,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          ...children,
        ],
      ),
    );
  }

  Widget _switchTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    bool enabled = true,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SwitchListTile(
      secondary: Icon(icon, color: enabled ? AppColors.primary : Colors.grey),
      title: Text(
        title,
        style: TextStyle(
          color: isDark ? const Color(0xFFE6E6E6) : const Color(0xFF172033),
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          color: isDark ? const Color(0xFFB0B0B0) : const Color(0xFF64748B),
        ),
      ),
      value: value,
      activeThumbColor: AppColors.primary,
      onChanged: enabled ? onChanged : null,
    );
  }

  Future<void> _showChangePasswordDialog(BuildContext context) async {
    final controller = TextEditingController();

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        bool savingPassword = false;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Change Password'),
              content: TextField(
                controller: controller,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'New password',
                  border: OutlineInputBorder(),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: savingPassword
                      ? null
                      : () => Navigator.pop(dialogContext),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: savingPassword
                      ? null
                      : () async {
                          if (controller.text.trim().length < 6) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Password must contain at least 6 characters.',
                                ),
                              ),
                            );
                            return;
                          }

                          setDialogState(() => savingPassword = true);

                          try {
                            await FirebaseAuth.instance.currentUser
                                ?.updatePassword(controller.text.trim());

                            if (dialogContext.mounted) {
                              Navigator.pop(dialogContext);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Password updated.'),
                                ),
                              );
                            }
                          } on FirebaseAuthException catch (e) {
                            if (dialogContext.mounted) {
                              ScaffoldMessenger.of(dialogContext).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    e.message ?? 'Unable to update password.',
                                  ),
                                ),
                              );
                              setDialogState(() => savingPassword = false);
                            }
                          }
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Update'),
                ),
              ],
            );
          },
        );
      },
    );

    controller.dispose();
  }

  void _showAboutDialog(BuildContext context) {
    showAboutDialog(
      context: context,
      applicationName: 'LifeLink',
      applicationVersion: '1.0',
      applicationIcon: const Icon(
        Icons.bloodtype,
        color: AppColors.primary,
        size: 40,
      ),
      children: const [
        Text(
          'LifeLink connects blood donors, patients, hospitals and blood banks '
          'to support faster blood-request coordination.',
        ),
      ],
    );
  }
}

class HelpPage extends StatelessWidget {
  const HelpPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Help'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _helpTile(
            icon: Icons.bloodtype_outlined,
            title: 'How do I request blood?',
            message:
                'Open the blood request section, select the required blood '
                'group and units, enter the hospital details, and submit the request.',
          ),
          _helpTile(
            icon: Icons.location_on_outlined,
            title: 'How does location matching work?',
            message:
                'Update your location from the location section. LifeLink can '
                'use it to support nearby blood-request matching.',
          ),
          _helpTile(
            icon: Icons.swap_horiz,
            title: 'How do I switch roles?',
            message: 'Open the profile menu and select Switch Role.',
          ),
          _helpTile(
            icon: Icons.settings_outlined,
            title: 'Where are my settings?',
            message:
                'Open the profile menu and select Settings to manage notifications, '
                'privacy, location and account preferences.',
          ),
          _helpTile(
            icon: Icons.contact_support_outlined,
            title: 'Need further assistance?',
            message:
                'Contact your LifeLink administrator or project support team '
                'for account or service-related assistance.',
          ),
        ],
      ),
    );
  }

  Widget _helpTile({
    required IconData icon,
    required String title,
    required String message,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ExpansionTile(
        leading: Icon(icon, color: AppColors.primary),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              message,
              style: const TextStyle(color: Colors.grey, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyFeatureState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;

  const _EmptyFeatureState({
    required this.icon,
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(30),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const LifeLinkMascot(compact: false),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark
                    ? const Color(0xFF352029)
                    : const Color(0xFFFFF0F3),
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Text(
                'Your LifeLink friends are here to help',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.primary,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(height: 14),
            Icon(icon, color: AppColors.primary, size: 36),
            const SizedBox(height: 12),
            Text(
              title,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.onSurface,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              message,
              style: TextStyle(
                color: Theme.of(context).brightness == Brightness.dark
                    ? const Color(0xFFD0BEC4)
                    : AppColors.mutedText,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class DonationHistoryPage extends StatelessWidget {
  const DonationHistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Donation History'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: user == null
          ? const Center(child: Text('Please login again.'))
          : FutureBuilder<QuerySnapshot<Map<String, dynamic>>>(
              future: FirebaseFirestore.instance
                  .collection('donations')
                  .where('donorId', isEqualTo: user.uid)
                  .get(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(color: AppColors.primary),
                  );
                }

                if (snapshot.hasError) {
                  return const _EmptyFeatureState(
                    icon: Icons.history_outlined,
                    title: 'No donation history',
                    message: 'Completed donations will appear here when they are recorded.',
                  );
                }

                final docs = snapshot.data?.docs ?? [];

                if (docs.isEmpty) {
                  return const _EmptyFeatureState(
                    icon: Icons.history_outlined,
                    title: 'No donation history',
                    message: 'Completed donations will appear here when they are recorded.',
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final data = docs[index].data();
                    final bloodGroup =
                        data['bloodGroup']?.toString() ?? 'Not specified';
                    final hospital =
                        data['hospital']?.toString() ??
                        'Hospital not specified';
                    final units = data['units']?.toString() ?? '1';
                    final status = data['status']?.toString() ?? 'Completed';

                    return _recordCard(
                      icon: Icons.bloodtype_outlined,
                      title: '$bloodGroup Blood Donation',
                      lines: [
                        'Hospital: $hospital',
                        'Units: $units',
                        'Status: $status',
                      ],
                    );
                  },
                );
              },
            ),
    );
  }

  Widget _recordCard({
    required IconData icon,
    required String title,
    required List<String> lines,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const CircleAvatar(
            backgroundColor: AppColors.softTeal,
            child: Icon(Icons.bloodtype_outlined, color: AppColors.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 7),
                ...lines.map(
                  (line) => Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(
                      line,
                      style: const TextStyle(color: Colors.grey),
                    ),
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

class CertificatesPage extends StatelessWidget {
  const CertificatesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Certificates'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: user == null
          ? const Center(child: Text('Please login again.'))
          : FutureBuilder<QuerySnapshot<Map<String, dynamic>>>(
              future: FirebaseFirestore.instance
                  .collection('certificates')
                  .where('userId', isEqualTo: user.uid)
                  .get(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(color: AppColors.primary),
                  );
                }

                if (snapshot.hasError) {
                  return const _EmptyFeatureState(
                    icon: Icons.card_membership_outlined,
                    title: 'No certificates',
                    message: 'Donation certificates will appear here when they are issued.',
                  );
                }

                final docs = snapshot.data?.docs ?? [];

                if (docs.isEmpty) {
                  return const _EmptyFeatureState(
                    icon: Icons.card_membership_outlined,
                    title: 'No certificates',
                    message: 'Donation certificates will appear here when they are issued.',
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final data = docs[index].data();
                    final title =
                        data['title']?.toString() ??
                        'Blood Donation Certificate';
                    final hospital =
                        data['hospital']?.toString() ??
                        'Hospital not specified';
                    final date =
                        data['date']?.toString() ?? 'Date not specified';

                    return Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.grey.shade200),
                      ),
                      child: Row(
                        children: [
                          const CircleAvatar(
                            backgroundColor: AppColors.softTeal,
                            child: Icon(
                              Icons.workspace_premium_outlined,
                              color: AppColors.primary,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  title,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  hospital,
                                  style: const TextStyle(color: Colors.grey),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  date,
                                  style: const TextStyle(color: Colors.grey),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: 'View certificate',
                            icon: const Icon(
                              Icons.visibility_outlined,
                              color: AppColors.primary,
                            ),
                            onPressed: () {
                              showDialog<void>(
                                context: context,
                                builder: (_) => AlertDialog(
                                  title: const Text('Certificate'),
                                  content: Text(
                                    '$title\n\nHospital: $hospital\nDate: $date',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(context),
                                      child: const Text('Close'),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
    );
  }
}

void showAccountMenu(BuildContext context, String role) {
  final user = FirebaseAuth.instance.currentUser;
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) {
      return SafeArea(
        child: DraggableScrollableSheet(
          initialChildSize: .58,
          minChildSize: .45,
          maxChildSize: .88,
          expand: false,
          builder: (_, controller) {
            return Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              ),
              child: ListView(
                controller: controller,
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                children: [
                  Center(
                    child: Container(
                      width: 42,
                      height: 5,
                      decoration: BoxDecoration(
                        color: AppColors.border,
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  const CircleAvatar(
                    radius: 30,
                    backgroundColor: AppColors.softTeal,
                    child: Icon(
                      Icons.person_outline,
                      color: AppColors.primary,
                      size: 34,
                    ),
                  ),
                  const SizedBox(height: 10),
                  FutureBuilder<String>(
                    future: _getCurrentUserName(),
                    builder: (context, snapshot) => Text(
                      snapshot.data ?? role,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    user?.email ?? '',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.mutedText,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Center(child: llStatusChip(role)),
                  const SizedBox(height: 14),
                  _profileSheetTile(
                    icon: Icons.person_outline,
                    title: 'My Profile',
                    onTap: () {
                      Navigator.pop(sheetContext);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ProfilePage(role: role),
                        ),
                      );
                    },
                  ),
                  _profileSheetTile(
                    icon: Icons.swap_horiz,
                    title: 'Switch Role',
                    onTap: () {
                      Navigator.pop(sheetContext);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => RoleSwitchPage(currentRole: role),
                        ),
                      );
                    },
                  ),
                  _profileSheetTile(
                    icon: Icons.settings_outlined,
                    title: 'Settings',
                    onTap: () {
                      Navigator.pop(sheetContext);
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const SettingsPage()),
                      );
                    },
                  ),
                  _profileSheetTile(
                    icon: Icons.help_outline,
                    title: 'Help & Support',
                    onTap: () {
                      Navigator.pop(sheetContext);
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const HelpPage()),
                      );
                    },
                  ),
                  _profileSheetTile(
                    icon: Icons.logout,
                    title: 'Logout',
                    color: AppColors.danger,
                    onTap: () async {
                      Navigator.pop(sheetContext);
                      await logoutUser(context);
                    },
                  ),
                ],
              ),
            );
          },
        ),
      );
    },
  );
}

Widget _profileSheetTile({
  required IconData icon,
  required String title,
  required VoidCallback onTap,
  Color color = AppColors.navy,
}) {
  return Container(
    margin: const EdgeInsets.only(bottom: 8),
    decoration: BoxDecoration(
      color: AppColors.background,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: AppColors.border),
    ),
    child: ListTile(
      leading: Icon(icon, color: color),
      title: Text(
        title,
        style: TextStyle(color: color, fontWeight: FontWeight.w600),
      ),
      trailing: const Icon(Icons.chevron_right, color: AppColors.mutedText),
      onTap: onTap,
    ),
  );
}

Future<String> _getCurrentUserName() async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return 'LifeLink User';

  try {
    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();

    final name = snapshot.data()?['name']?.toString().trim() ?? '';
    if (name.isNotEmpty) return name;
  } catch (_) {}

  final email = user.email ?? '';
  if (email.contains('@')) {
    final prefix = email.split('@').first.trim();
    if (prefix.isNotEmpty) return prefix;
  }

  return 'LifeLink User';
}

class DashboardBackScope extends StatelessWidget {
  final String role;
  final Widget child;

  const DashboardBackScope({
    super.key,
    required this.role,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        // If this dashboard was opened from another screen, let Flutter
        // perform the normal Back navigation.
        if (Navigator.of(context).canPop()) {
          return true;
        }

        // The role dashboard is the app's home for the active role.
        // Do not close the app when the Android system Back button is
        // pressed from here.
        return false;
      },
      child: child,
    );
  }
}

// ============================================================
// DONOR PAGE
// ============================================================

class DonorPage extends StatefulWidget {
  const DonorPage({super.key});

  @override
  State<DonorPage> createState() => _DonorPageState();
}

class _DonorPageState extends State<DonorPage> {
  bool isAvailable = true;
  String donorName = 'Donor';
  String donorBloodGroup = 'Not set';
  int donationCount = 0;
  bool loadingProfile = true;
  Position? currentPosition;
  bool isLoadingLocation = false;
  double? hospitalDistance;

  // Distance is calculated against each request's saved coordinates, not (0, 0).

  @override
  void initState() {
    super.initState();
    _loadDonorData();
  }

  Future<void> _loadDonorData() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      final data = doc.data() ?? {};
      final rawProfiles = data['roleProfiles'];
      final rawDonor = rawProfiles is Map ? rawProfiles['Donor'] : null;
      final donorProfile = rawDonor is Map
          ? Map<String, dynamic>.from(rawDonor)
          : <String, dynamic>{};
      final loadedName = donorProfile['name']?.toString().trim() ?? '';
      final loadedBloodGroup =
          (donorProfile['bloodGroup'] ??
                  donorProfile['blood_group'] ??
                  data['bloodGroup'] ??
                  data['blood_group'])
              ?.toString()
              .trim();
      if (!mounted) return;
      setState(() {
        donorName = loadedName.isNotEmpty
            ? loadedName
            : (user.email?.split('@').first ?? 'Donor');
        donorBloodGroup = (loadedBloodGroup == null || loadedBloodGroup.isEmpty)
            ? 'Not set'
            : loadedBloodGroup.toUpperCase();
        donationCount = (donorProfile['donationCount'] as num?)?.toInt() ?? 0;
        isAvailable = donorProfile['available'] != false;
        loadingProfile = false;
      });
    } catch (_) {
      if (mounted) setState(() => loadingProfile = false);
    }
  }

  Future<void> _updateAvailability(bool value) async {
    final user = FirebaseAuth.instance.currentUser;
    setState(() => isAvailable = value);
    if (user == null) return;
    try {
      await updateRoleProfileFields('Donor', {
        'available': value,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {
      if (mounted) setState(() => isAvailable = !value);
    }
  }

  Future<void> getCurrentLocation() async {
    setState(() => isLoadingLocation = true);

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();

      if (!serviceEnabled) {
        setState(() => isLoadingLocation = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Please turn on location services.')),
          );
        }
        return;
      }

      var permission = await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        setState(() => isLoadingLocation = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Location permission denied.')),
          );
        }
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      setState(() {
        currentPosition = position;
        hospitalDistance =
            null; // Computed per request using its saved coordinates.
        isLoadingLocation = false;
      });

      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        await updateRoleProfileFields('Donor', {
          'latitude': position.latitude,
          'longitude': position.longitude,
          'locationUpdatedAt': FieldValue.serverTimestamp(),
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Location and distance updated!')),
        );
      }
    } catch (e) {
      setState(() => isLoadingLocation = false);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Unable to get location: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('LifeLink'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.notifications_none),
            tooltip: 'Notifications',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const NotificationsPage()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.person_outline),
            tooltip: 'Account',
            onPressed: () => showAccountMenu(context, 'Donor'),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const RoleProfileLabel(role: 'Donor'),
            const UserGreeting(
              role: 'Donor',
              subtitle: 'Your contribution can save a life.',
            ),
            const SizedBox(height: 20),

            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: Row(
                children: [
                  const CircleAvatar(
                    radius: 30,
                    backgroundColor: AppColors.primary,
                    child: Icon(
                      Icons.person_outline,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                  const SizedBox(width: 15),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          donorName,
                          style: const TextStyle(
                            color: Color(0xFF212121),
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          'Blood Group: $donorBloodGroup',
                          style: const TextStyle(color: Color(0xFF555555)),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '$donationCount previous donation${donationCount == 1 ? '' : 's'}',
                          style: const TextStyle(
                            color: Color(0xFF555555),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.verified_outlined, color: AppColors.primary),
                ],
              ),
            ),

            const SizedBox(height: 20),

            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Donation Availability',
                          style: TextStyle(
                            color: Color(0xFF212121),
                            fontWeight: FontWeight.bold,
                            fontSize: 17,
                          ),
                        ),
                        SizedBox(height: 5),
                        Text(
                          'Allow LifeLink to notify you about requests.',
                          style: TextStyle(color: Color(0xFF555555)),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: isAvailable,
                    activeColor: AppColors.primary,
                    onChanged: _updateAvailability,
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            const SizedBox(height: 20),
            const Text(
              'Blood Requests For You',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              // Listen to the whole collection so legacy requests with status
              // values such as 'pending' are not silently excluded by Firestore.
              stream: FirebaseFirestore.instance
                  .collection('blood_requests')
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(20),
                      child: CircularProgressIndicator(
                        color: AppColors.primary,
                      ),
                    ),
                  );
                }
                if (snapshot.hasError) {
                  return Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Text(
                      'Unable to load blood requests: ${snapshot.error}',
                      style: const TextStyle(color: Colors.red),
                    ),
                  );
                }

                final user = FirebaseAuth.instance.currentUser;
                final group = donorBloodGroup.trim().toUpperCase();
                final requests =
                    (snapshot.data?.docs ?? []).map(BloodRequest.fromDoc).where(
                      (request) {
                        final isOwn =
                            user != null &&
                            (request.createdBy == user.uid ||
                                request.patientId == user.uid);
                        return !isOwn &&
                            group.isNotEmpty &&
                            group != 'NOT SET' &&
                            request.status.trim().toLowerCase() == 'pending' &&
                            canDonorDonateTo(
                              group,
                              request.bloodGroup.trim().toUpperCase(),
                            );
                      },
                    ).toList()..sort(
                      (a, b) =>
                          (b.createdAt ??
                                  DateTime.fromMillisecondsSinceEpoch(0))
                              .compareTo(
                                a.createdAt ??
                                    DateTime.fromMillisecondsSinceEpoch(0),
                              ),
                    );

                if (requests.isEmpty) {
                  return Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: Colors.grey.shade200),
                    ),
                    child: const Column(
                      children: [
                        Icon(
                          Icons.assignment_outlined,
                          size: 38,
                          color: Colors.grey,
                        ),
                        SizedBox(height: 8),
                        Text(
                          'No matching blood requests',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'New compatible requests will appear here automatically.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Color(0xFF555555)),
                        ),
                      ],
                    ),
                  );
                }

                return Column(
                  children: requests.map((request) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: requestCard(context, request),
                    );
                  }).toList(),
                );
              },
            ),

            const SizedBox(height: 20),
            const Text(
              'Quick Actions',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),

            Row(
              children: [
                Expanded(
                  child: quickAction(
                    Icons.card_membership_outlined,
                    'Certificates',
                    () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const CertificatesPage(),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: quickAction(
                    Icons.history_outlined,
                    'Donation History',
                    () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const RoleHistoryPage(role: 'Donor'),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),

      bottomNavigationBar: RoleBottomNav(role: 'Donor', currentIndex: 0),
    );
  }

  Widget requestCard(BuildContext context, BloodRequest request) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const CircleAvatar(
                backgroundColor: AppColors.softTeal,
                child: Icon(Icons.bloodtype, color: AppColors.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      request.bloodGroup,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: AppColors.primary,
                      ),
                    ),
                    Text(
                      '${request.units} unit'
                      '${request.units > 1 ? 's' : ''} required',
                      style: const TextStyle(
                        color: Color(0xFF212121),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              if (request.emergency)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text(
                    'URGENT',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 15),
          Text(
            'Patient: ${request.patientName}',
            style: const TextStyle(
              color: Color(0xFF212121),
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            request.hospital,
            style: const TextStyle(
              color: Color(0xFF212121),
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 5),
          Builder(
            builder: (context) {
              double? distance;
              if (currentPosition != null &&
                  request.patientLatitude != null &&
                  request.patientLongitude != null) {
                distance =
                    Geolocator.distanceBetween(
                      currentPosition!.latitude,
                      currentPosition!.longitude,
                      request.patientLatitude!,
                      request.patientLongitude!,
                    ) /
                    1000;
              } else {
                distance = hospitalDistance;
              }
              return Text(
                distance == null
                    ? 'Distance not calculated'
                    : '${distance.toStringAsFixed(2)} km away',
                style: const TextStyle(
                  color: Color(0xFF555555),
                  fontWeight: FontWeight.bold,
                ),
              );
            },
          ),
          const SizedBox(height: 15),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () async {
                activeBloodRequest = request;
                activeBloodRequestId = request.id;
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => BloodRequestPage(
                      donorPosition: currentPosition,
                      hospitalDistance: hospitalDistance,
                    ),
                  ),
                );
                setState(() {});
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
              ),
              child: const Text('View Request'),
            ),
          ),
        ],
      ),
    );
  }

  Widget quickAction(IconData icon, String title, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(15),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(15),
        ),
        child: Column(
          children: [
            Icon(icon, color: AppColors.primary, size: 30),
            const SizedBox(height: 8),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFF333333),
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void showComingSoon(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('This feature will be added soon.')),
    );
  }
}

// ============================================================
// DONOR LIST / PRIORITY SUGGESTIONS
// ============================================================

class NearbyDonorsPage extends StatefulWidget {
  final String role;
  const NearbyDonorsPage({super.key, this.role = 'Patient'});

  @override
  State<NearbyDonorsPage> createState() => _NearbyDonorsPageState();
}

class _NearbyDonorsPageState extends State<NearbyDonorsPage> {
  String selectedGroup = 'All';
  String selectedCity = '';
  double selectedRadius = 10;
  String search = '';
  final TextEditingController searchController = TextEditingController();

  List<String> get _matchingAreaSuggestions {
    final query = search.trim().toLowerCase();
    if (query.length < 2) return const [];
    return chennaiAreas
        .where(
          (area) => area != 'All Areas' && area.toLowerCase().startsWith(query),
        )
        .take(5)
        .toList();
  }

  Position? origin;
  bool loading = true;
  List<Donor> donors = [];
  List<Donor> _loadedDonors = [];

  void _applyLocalSearch() {
    final q = search.trim().toLowerCase();
    final filtered = q.isEmpty
        ? List<Donor>.from(_loadedDonors)
        : _loadedDonors.where((d) {
            return d.name.toLowerCase().contains(q) ||
                d.bloodGroup.toLowerCase().contains(q) ||
                d.city.toLowerCase().contains(q);
          }).toList();
    if (mounted) setState(() => donors = filtered);
  }

  final cityController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadOriginAndDonors();
  }

  Future<void> _loadOriginAndDonors() async {
    setState(() => loading = true);
    try {
      final profile = await getRoleProfile(widget.role);
      final profileLat = (profile['latitude'] as num?)?.toDouble();
      final profileLon = (profile['longitude'] as num?)?.toDouble();

      if (profileLat != null && profileLon != null) {
        origin = Position(
          latitude: profileLat,
          longitude: profileLon,
          timestamp: DateTime.now(),
          accuracy: 10,
          altitude: 0,
          heading: 0,
          speed: 0,
          speedAccuracy: 0,
          altitudeAccuracy: 0,
          headingAccuracy: 0,
        );
      } else {
        origin = Position(
          latitude: 13.0569,
          longitude: 80.2425,
          timestamp: DateTime.now(),
          accuracy: 100,
          altitude: 0,
          heading: 0,
          speed: 0,
          speedAccuracy: 0,
          altitudeAccuracy: 0,
          headingAccuracy: 0,
        );
      }
      await _reload();
    } catch (_) {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _useCurrentLocation() async {
    final position = await getDeviceLocation();
    if (position == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Enable location permission to search by distance.'),
          ),
        );
      }
      return;
    }

    origin = position;
    await updateRoleProfileFields(widget.role, {
      'latitude': position.latitude,
      'longitude': position.longitude,
      'locationUpdatedAt': FieldValue.serverTimestamp(),
    });
    await _reload();
  }

  Future<void> _reload() async {
    setState(() => loading = true);
    try {
      // 'All' means do not filter by blood group. A specific group applies
      // the donor-to-recipient compatibility rules in fetchPriorityDonors.
      final effectiveGroup = selectedGroup == 'All' ? 'ALL' : selectedGroup;

      _loadedDonors = await fetchPriorityDonors(
        bloodGroup: effectiveGroup,
        city: selectedCity.trim(),
        radiusKm: selectedRadius,
        originLatitude: origin?.latitude,
        originLongitude: origin?.longitude,
      );
      final q = search.trim().toLowerCase();
      donors = q.isEmpty
          ? List<Donor>.from(_loadedDonors)
          : _loadedDonors.where((d) {
              return d.name.toLowerCase().contains(q) ||
                  d.bloodGroup.toLowerCase().contains(q) ||
                  d.city.toLowerCase().contains(q);
            }).toList();
    } catch (_) {
      donors = [];
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  void dispose() {
    cityController.dispose();
    searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final groupOptions = ['All', ...allBloodGroups];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Priority Donors'),
        actions: [
          IconButton(
            tooltip: 'Use current location',
            icon: const Icon(Icons.my_location),
            onPressed: _useCurrentLocation,
          ),
          IconButton(
            tooltip: 'Notifications',
            icon: const Icon(Icons.notifications_none),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const NotificationsPage()),
            ),
          ),
        ],
      ),
      body: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Text(
              'Search donors by blood group, area and distance. Priority: exact blood-group match, donation history, then distance. Demo profiles are simulated for presentation only.',
              style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
            child: TextField(
              controller: searchController,
              textInputAction: TextInputAction.search,
              onChanged: (v) {
                search = v;
                // Filter the already-loaded donor list locally so typing
                // doesn't trigger repeated Firestore reads or reset the list.
                _applyLocalSearch();
              },
              decoration: const InputDecoration(
                hintText: 'Search donor name, blood group or area',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),
          if (_matchingAreaSuggestions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Card(
                margin: EdgeInsets.zero,
                elevation: 2,
                clipBehavior: Clip.antiAlias,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: _matchingAreaSuggestions.map((area) {
                    return ListTile(
                      dense: true,
                      leading: const Icon(
                        Icons.location_on_outlined,
                        color: AppColors.primary,
                      ),
                      title: Text(area),
                      subtitle: const Text('Chennai area'),
                      onTap: () async {
                        FocusScope.of(context).unfocus();
                        setState(() {
                          selectedCity = area;
                          search = '';
                          searchController.clear();
                        });
                        await _reload();
                      },
                    );
                  }).toList(),
                ),
              ),
            ),
          SizedBox(
            height: 48,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
              scrollDirection: Axis.horizontal,
              itemCount: groupOptions.length,
              separatorBuilder: (_, __) => const SizedBox(width: 7),
              itemBuilder: (_, i) {
                final f = groupOptions[i];
                return ChoiceChip(
                  label: Text(f),
                  selected: selectedGroup == f,
                  onSelected: (_) async {
                    setState(() => selectedGroup = f);
                    await _reload();
                  },
                  selectedColor: AppColors.primary,
                  labelStyle: TextStyle(
                    color: selectedGroup == f ? Colors.white : AppColors.navy,
                    fontWeight: FontWeight.w700,
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: selectedCity.isEmpty ? 'All Areas' : selectedCity,
                    decoration: const InputDecoration(
                      labelText: 'Chennai Area',
                      prefixIcon: Icon(Icons.location_on_outlined),
                    ),
                    items: chennaiAreas
                        .map(
                          (area) => DropdownMenuItem<String>(
                            value: area,
                            child: Text(area),
                          ),
                        )
                        .toList(),
                    onChanged: (value) async {
                      if (value == null) return;
                      setState(() {
                        selectedCity = value == 'All Areas' ? '' : value;
                        search = '';
                        searchController.clear();
                      });
                      await _reload();
                    },
                  ),
                ),
                const SizedBox(width: 10),
                DropdownButton<double>(
                  value: selectedRadius,
                  items: const [
                    DropdownMenuItem(value: 5, child: Text('5 km')),
                    DropdownMenuItem(value: 10, child: Text('10 km')),
                    DropdownMenuItem(value: 15, child: Text('15 km')),
                    DropdownMenuItem(value: 20, child: Text('20 km')),
                    DropdownMenuItem(value: 25, child: Text('25 km')),
                  ],
                  onChanged: (value) async {
                    if (value == null) return;
                    setState(() => selectedRadius = value);
                    await _reload();
                  },
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _reload,
                icon: const Icon(Icons.filter_alt_outlined),
                label: Text(
                  'Apply filters • ${selectedRadius.toStringAsFixed(0)} km',
                ),
              ),
            ),
          ),
          if (loading)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(
                child: CircularProgressIndicator(color: AppColors.primary),
              ),
            )
          else if (donors.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 20, 16, 28),
              child: _EmptyFeatureState(
                icon: Icons.people_outline,
                title: 'No matching donors',
                message: 'Try another name, blood group, area or distance.',
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${donors.length} potential donor${donors.length == 1 ? '' : 's'} found',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Refresh donors',
                        onPressed: _reload,
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                  ...List.generate(donors.length, (i) {
                    final donor = donors[i];
                    final distance = donorDistanceKm(
                      donor,
                      origin?.latitude,
                      origin?.longitude,
                    );
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _DonorDirectoryCard(
                        donor: donor,
                        priority: i < 5,
                        rank: i + 1,
                        distanceKm: distance,
                        requestRole: widget.role,
                      ),
                    );
                  }),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _DonorDirectoryCard extends StatelessWidget {
  final Donor donor;
  final bool priority;
  final int rank;
  final double distanceKm;
  final String requestRole;

  const _DonorDirectoryCard({
    required this.donor,
    required this.priority,
    required this.rank,
    required this.distanceKm,
    required this.requestRole,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: donor.id == null
            ? null
            : () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => DonorDetailsPage(
                    donor: donor,
                    distanceKm: distanceKm,
                    requestRole: requestRole,
                  ),
                ),
              ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              CircleAvatar(
                radius: 25,
                backgroundColor: AppColors.softTeal,
                child: Text(
                  '$rank',
                  style: const TextStyle(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            donor.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                        ),
                        if (priority) ...[
                          const SizedBox(width: 7),
                          llStatusChip('Priority donor'),
                        ],
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '${donor.bloodGroup} • ${donor.donationCount} donations',
                      style: const TextStyle(
                        color: AppColors.mutedText,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      distanceKm.isFinite
                          ? '${distanceKm.toStringAsFixed(1)} km away'
                          : 'Distance unavailable',
                      style: const TextStyle(
                        color: AppColors.success,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: AppColors.mutedText),
            ],
          ),
        ),
      ),
    );
  }
}

class DonorDetailsPage extends StatelessWidget {
  final Donor donor;
  final double distanceKm;
  final String requestRole;

  const DonorDetailsPage({
    super.key,
    required this.donor,
    required this.distanceKm,
    required this.requestRole,
  });

  Future<void> _sendRequest(BuildContext context) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || donor.id == null || donor.id!.startsWith('demo_')) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Demo donor selected. Use this profile to demonstrate priority ranking; real requests require a registered donor.',
            ),
          ),
        );
      }
      return;
    }

    try {
      final profile = await getRoleProfile(requestRole);
      final requestId = activeBloodRequestId;

      await createLifeLinkNotification(
        userId: donor.id!,
        senderId: user.uid,
        requestId: requestId,
        type: 'direct_donor_request',
        bloodGroup: donor.bloodGroup,
        title: 'Direct blood request',
        message:
            '${profile['name'] ?? 'A LifeLink user'} is requesting ${donor.bloodGroup} blood.',
      );

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Request sent to ${donor.name}.')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Unable to send request: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Donor Details')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: CircleAvatar(
                radius: 45,
                backgroundColor: AppColors.softTeal,
                child: Text(
                  donor.name.isNotEmpty ? donor.name[0].toUpperCase() : '?',
                  style: const TextStyle(
                    fontSize: 30,
                    color: AppColors.primary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: Text(
                donor.name,
                style: const TextStyle(
                  fontSize: 25,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(height: 20),
            _detailTile(Icons.bloodtype, 'Blood Group', donor.bloodGroup),
            _detailTile(
              Icons.location_city,
              'City',
              donor.city.isEmpty ? 'Not provided' : donor.city,
            ),
            _detailTile(
              Icons.volunteer_activism,
              'Blood Donations',
              '${donor.donationCount}',
            ),
            _detailTile(
              Icons.location_on_outlined,
              'Distance',
              distanceKm.isFinite
                  ? '${distanceKm.toStringAsFixed(1)} km'
                  : 'Not available',
            ),
            _detailTile(
              Icons.check_circle_outline,
              'Availability',
              donor.available ? 'Available now' : 'Unavailable',
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: donor.available ? () => _sendRequest(context) : null,
                icon: const Icon(Icons.send),
                label: const Text('Send Request Notification'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _detailTile(IconData icon, String title, String value) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Icon(icon, color: AppColors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '$title: $value',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// BLOOD REQUEST PAGE
// ============================================================

class BloodRequestPage extends StatefulWidget {
  final Position? donorPosition;
  final double? hospitalDistance;
  final String viewerRole;

  const BloodRequestPage({
    super.key,
    required this.donorPosition,
    required this.hospitalDistance,
    this.viewerRole = 'Donor',
  });

  @override
  State<BloodRequestPage> createState() => _BloodRequestPageState();
}

class _BloodRequestPageState extends State<BloodRequestPage> {
  Position? _distancePosition;
  bool _loadingDistancePosition = false;

  @override
  void initState() {
    super.initState();
    _distancePosition = widget.donorPosition;
    if (_distancePosition == null && widget.viewerRole == 'Donor') {
      _loadDistancePosition();
    }
  }

  Future<void> _loadDistancePosition() async {
    if (_loadingDistancePosition) return;
    _loadingDistancePosition = true;
    try {
      final position = await getDeviceLocation();
      if (mounted && position != null) {
        setState(() => _distancePosition = position);
      }
    } finally {
      _loadingDistancePosition = false;
    }
  }

  double? _requestDistanceKm(BloodRequest request) {
    final position = _distancePosition ?? widget.donorPosition;
    final lat = request.patientLatitude;
    final lon = request.patientLongitude;
    if (position == null || lat == null || lon == null)
      return widget.hospitalDistance;
    return Geolocator.distanceBetween(
          position.latitude,
          position.longitude,
          lat,
          lon,
        ) /
        1000.0;
  }

  Future<void> openNavigation() async {
    final request = activeBloodRequest;
    if (request == null) return;

    if (request.patientLatitude == null || request.patientLongitude == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'This request has no verified hospital coordinates. Ask the hospital to set its exact location in its profile.',
          ),
        ),
      );
      return;
    }

    final current = widget.donorPosition ?? await getDeviceLocation();
    if (current == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enable location permission.')),
      );
      return;
    }

    final url = Uri.parse(
      'https://www.google.com/maps/dir/?api=1'
      '&origin=${current.latitude},'
      '${current.longitude}'
      '&destination=${request.patientLatitude},${request.patientLongitude}'
      '&travelmode=driving',
    );

    await launchUrl(url, mode: LaunchMode.externalApplication);
  }

  Future<void> acceptRequest() async {
    final request = activeBloodRequest;
    final user = FirebaseAuth.instance.currentUser;
    if (request?.id == null || user == null) return;

    try {
      final profile = await getRoleProfile('Donor');
      final donorName = profile['name']?.toString() ?? 'Donor';
      await FirebaseFirestore.instance
          .collection('blood_requests')
          .doc(request!.id!)
          .update({
            'status': 'Accepted by donor',
            'donorId': user.uid,
            'donorName': donorName,
            'updatedAt': FieldValue.serverTimestamp(),
          });
      request.status = 'Accepted by donor';
      request.donorId = user.uid;
      request.donorName = donorName;
      final recipientId = request.patientId ?? request.createdBy;
      if (recipientId != null && recipientId.isNotEmpty) {
        await createLifeLinkNotification(
          userId: recipientId,
          senderId: user.uid,
          requestId: request.id,
          type: 'request_accepted',
          bloodGroup: request.bloodGroup,
          title: 'Donor accepted your request',
          message:
              '$donorName accepted your ${request.bloodGroup} blood request.',
        );
      }
      if (mounted) setState(() {});
      // Start donor GPS sharing immediately after the request is accepted.
      if (mounted) {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => DonorLiveLocationPage(
              requestId: request.id!,
              patientLatitude: request.patientLatitude ?? 0,
              patientLongitude: request.patientLongitude ?? 0,
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Unable to accept request: $e')));
      }
      return;
    }

    showDialog(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: const Text('Request Accepted'),
          content: const Text(
            'Thank you! The patient has been notified that you are willing to donate.',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                Navigator.pop(context);
              },
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  Future<void> rejectRequest() async {
    final request = activeBloodRequest;
    final user = FirebaseAuth.instance.currentUser;
    if (request?.id == null || user == null) return;

    try {
      final profile = await getRoleProfile('Donor');
      final donorName = profile['name']?.toString() ?? 'Donor';
      await FirebaseFirestore.instance
          .collection('blood_requests')
          .doc(request!.id!)
          .update({
            'status': 'Rejected by donor',
            'donorId': user.uid,
            'donorName': donorName,
            'updatedAt': FieldValue.serverTimestamp(),
          });
      request.status = 'Rejected by donor';

      final recipientId = request.patientId ?? request.createdBy;
      if (recipientId != null && recipientId.isNotEmpty) {
        await createLifeLinkNotification(
          userId: recipientId,
          senderId: user.uid,
          requestId: request.id,
          type: 'request_rejected',
          bloodGroup: request.bloodGroup,
          title: 'Donor declined your request',
          message:
              'The selected donor declined the ${request.bloodGroup} blood request. You can search another priority donor.',
        );
      }

      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Unable to reject request: $e')));
      }
    }
  }

  Widget buildMap() {
    final request = activeBloodRequest;
    final hospitalLocation =
        request?.patientLatitude != null && request?.patientLongitude != null
        ? LatLng(request!.patientLatitude!, request.patientLongitude!)
        : null;

    final donorLocation = widget.donorPosition == null
        ? null
        : LatLng(
            widget.donorPosition!.latitude,
            widget.donorPosition!.longitude,
          );

    return SizedBox(
      height: 350,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(15),
        child: FlutterMap(
          options: MapOptions(
            initialCenter:
                donorLocation ??
                hospitalLocation ??
                const LatLng(13.0827, 80.2707),
            initialZoom: donorLocation != null && hospitalLocation != null
                ? 12
                : 14,
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.example.lifelink',
            ),
            MarkerLayer(
              markers: [
                if (hospitalLocation != null)
                  Marker(
                    point: hospitalLocation,
                    width: 60,
                    height: 60,
                    child: const Icon(
                      Icons.local_hospital,
                      color: AppColors.primary,
                      size: 42,
                    ),
                  ),
                if (donorLocation != null)
                  Marker(
                    point: donorLocation,
                    width: 60,
                    height: 60,
                    child: const Icon(
                      Icons.person_pin_circle,
                      color: AppColors.primary,
                      size: 42,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final request = activeBloodRequest;

    if (request == null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Blood Request'),
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
        ),
        body: const Center(child: Text('No active blood request.')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Blood Request'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              color: AppColors.primary,
              child: const Column(
                children: [
                  Icon(Icons.warning_rounded, color: Colors.white, size: 50),
                  SizedBox(height: 10),
                  Text(
                    'Emergency Blood Request',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(15),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.bloodtype,
                          color: AppColors.primary,
                          size: 40,
                        ),
                      ),
                      const SizedBox(width: 15),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              request.bloodGroup,
                              style: const TextStyle(
                                color: AppColors.primary,
                                fontSize: 28,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              '${request.units} unit'
                              '${request.units > 1 ? 's' : ''} required',
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 25),
                  infoRow(Icons.local_hospital, 'Hospital', request.hospital),
                  const SizedBox(height: 15),
                  infoRow(Icons.person, 'Patient', request.patientName),
                  const SizedBox(height: 15),
                  infoRow(Icons.access_time, 'Status', request.status),
                  const SizedBox(height: 15),
                  infoRow(
                    Icons.location_on,
                    'Distance',
                    _requestDistanceKm(request) == null
                        ? (_loadingDistancePosition
                              ? 'Getting location…'
                              : 'Location not available')
                        : '${_requestDistanceKm(request)!.toStringAsFixed(2)} km',
                  ),
                  const SizedBox(height: 25),
                  const Text(
                    'Hospital Location',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  buildMap(),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: openNavigation,
                      icon: const Icon(Icons.navigation),
                      label: const Text('Navigate to Hospital'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 15),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (request.status == 'Pending')
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: acceptRequest,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 15),
                        ),
                        child: const Text('Accept Blood Request'),
                      ),
                    ),
                  if (widget.viewerRole == 'Donor' &&
                      request.status == 'Pending')
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: rejectRequest,
                          icon: const Icon(Icons.close),
                          label: const Text('Decline Request'),
                        ),
                      ),
                    ),
                  if (widget.viewerRole == 'Donor' &&
                      request.status == 'Accepted by donor' &&
                      request.donorId == FirebaseAuth.instance.currentUser?.uid)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => DonorLiveLocationPage(
                                  requestId: request.id!,
                                  patientLatitude:
                                      request.patientLatitude ?? 0.0,
                                  patientLongitude:
                                      request.patientLongitude ?? 0.0,
                                ),
                              ),
                            );
                          },
                          icon: const Icon(Icons.my_location),
                          label: const Text('Start Live Location'),
                        ),
                      ),
                    ),
                  if (widget.viewerRole != 'Donor' && request.donorId != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => DonorLiveLocationPage(
                                  requestId: request.id!,
                                  patientLatitude: request.patientLatitude ?? 0,
                                  patientLongitude:
                                      request.patientLongitude ?? 0,
                                ),
                              ),
                            );
                          },
                          icon: const Icon(Icons.my_location),
                          label: const Text('Share My Live Location'),
                        ),
                      ),
                    ),
                  if (widget.viewerRole != 'Donor' && request.donorId != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => DonorTrackingPage(
                                  requestId: request.id!,
                                  donorId: request.donorId!,
                                  patientLatitude: request.patientLatitude,
                                  patientLongitude: request.patientLongitude,
                                ),
                              ),
                            );
                          },
                          icon: const Icon(Icons.location_searching),
                          label: const Text('Track Donor Live'),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget infoRow(IconData icon, String title, String value) {
    return Row(
      children: [
        Icon(icon, color: AppColors.primary),
        const SizedBox(width: 12),
        Text('$title:', style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(value, style: const TextStyle(color: Colors.grey)),
        ),
      ],
    );
  }
}

// ============================================================
// LIVE DONOR TRACKING
// ============================================================

class DonorLiveLocationPage extends StatefulWidget {
  final String requestId;
  final double patientLatitude;
  final double patientLongitude;

  const DonorLiveLocationPage({
    super.key,
    required this.requestId,
    required this.patientLatitude,
    required this.patientLongitude,
  });

  @override
  State<DonorLiveLocationPage> createState() => _DonorLiveLocationPageState();
}

class _DonorLiveLocationPageState extends State<DonorLiveLocationPage> {
  StreamSubscription<Position>? subscription;
  Position? current;
  String? patientId;
  String? donorId;
  bool starting = true;
  String? locationError;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted)
        setState(() {
          starting = false;
          locationError = 'Please sign in to share location.';
        });
      return;
    }

    try {
      final requestDoc = await FirebaseFirestore.instance
          .collection('blood_requests')
          .doc(widget.requestId)
          .get();
      final data = requestDoc.data() ?? {};
      patientId = (data['patientId'] ?? data['createdBy'])?.toString();
      donorId = data['donorId']?.toString();

      // Only the accepted donor or the patient/request owner may share for this request.
      if (user.uid != patientId && user.uid != donorId) {
        throw StateError('This account is not part of this blood request.');
      }

      final position = await getDeviceLocation();
      if (position == null) {
        throw StateError(
          'Enable location services and allow LifeLink location permission.',
        );
      }
      await _write(position, user.uid);
      subscription =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.bestForNavigation,
              distanceFilter: 5,
            ),
          ).listen(
            (p) => _write(p, user.uid),
            onError: (Object e) {
              if (mounted)
                setState(() => locationError = 'GPS update failed: $e');
            },
          );

      if (mounted)
        setState(() {
          starting = false;
          locationError = null;
        });
    } catch (e) {
      if (mounted)
        setState(() {
          starting = false;
          locationError = e.toString().replaceFirst('Bad state: ', '');
        });
    }
  }

  Future<void> _write(Position position, String uid) async {
    current = position;
    if (mounted) setState(() {});
    await FirebaseFirestore.instance
        .collection('blood_requests')
        .doc(widget.requestId)
        .collection('live_locations')
        .doc(uid)
        .set({
          'userId': uid,
          'requestId': widget.requestId,
          'latitude': position.latitude,
          'longitude': position.longitude,
          'accuracy': position.accuracy,
          'updatedAt': FieldValue.serverTimestamp(),
          'active': true,
        }, SetOptions(merge: true));
  }

  Future<void> _stop() async {
    await subscription?.cancel();
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      try {
        await FirebaseFirestore.instance
            .collection('blood_requests')
            .doc(widget.requestId)
            .collection('live_locations')
            .doc(user.uid)
            .set({
              'requestId': widget.requestId,
              'active': false,
              'updatedAt': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final otherId = user?.uid == donorId ? patientId : donorId;
    return Scaffold(
      appBar: AppBar(title: const Text('Live Location Sharing')),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: otherId == null
            ? null
            : FirebaseFirestore.instance
                  .collection('blood_requests')
                  .doc(widget.requestId)
                  .collection('live_locations')
                  .doc(otherId)
                  .snapshots(),
        builder: (context, snapshot) {
          final otherData = snapshot.data?.data();
          final otherActive =
              otherData?['active'] == true &&
              otherData?['requestId']?.toString() == widget.requestId;
          final otherLat = otherActive
              ? (otherData?['latitude'] as num?)?.toDouble()
              : null;
          final otherLon = otherActive
              ? (otherData?['longitude'] as num?)?.toDouble()
              : null;
          final other = otherLat == null || otherLon == null
              ? null
              : LatLng(otherLat, otherLon);
          final own = current == null
              ? null
              : LatLng(current!.latitude, current!.longitude);
          final hospital =
              widget.patientLatitude != 0 && widget.patientLongitude != 0
              ? LatLng(widget.patientLatitude, widget.patientLongitude)
              : null;
          final center =
              own ?? other ?? hospital ?? const LatLng(13.0827, 80.2707);
          final markers = <Marker>[
            if (hospital != null)
              Marker(
                point: hospital,
                width: 70,
                height: 70,
                child: const Icon(
                  Icons.local_hospital,
                  color: Colors.deepOrange,
                  size: 46,
                ),
              ),
            if (own != null)
              Marker(
                point: own,
                width: 70,
                height: 70,
                child: const Icon(
                  Icons.my_location,
                  color: Colors.blue,
                  size: 44,
                ),
              ),
            if (other != null)
              Marker(
                point: other,
                width: 70,
                height: 70,
                child: const Icon(
                  Icons.location_pin,
                  color: AppColors.primary,
                  size: 48,
                ),
              ),
          ];
          return Column(
            children: [
              Expanded(
                child: FlutterMap(
                  options: MapOptions(
                    initialCenter: center,
                    initialZoom: 13,
                    keepAlive: true,
                    backgroundColor: const Color(0xFFE8EEF2),
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.lifelink.ai',
                      maxZoom: 19,
                      errorTileCallback: (tile, error, stackTrace) {
                        debugPrint('OpenStreetMap tile error: $error');
                      },
                    ),
                    MarkerLayer(markers: markers),
                    RichAttributionWidget(
                      attributions: [
                        TextSourceAttribution(
                          '© OpenStreetMap contributors',
                          onTap: () => launchUrl(
                            Uri.parse(
                              'https://www.openstreetmap.org/copyright',
                            ),
                            mode: LaunchMode.externalApplication,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      starting
                          ? 'Getting your GPS location…'
                          : current == null
                          ? (locationError ??
                                'Your live location is not available.')
                          : 'Your GPS: ${current!.latitude.toStringAsFixed(6)}, ${current!.longitude.toStringAsFixed(6)} • ±${current!.accuracy.toStringAsFixed(0)} m',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      otherActive && other != null
                          ? 'Other participant live GPS: ${other.latitude.toStringAsFixed(6)}, ${other.longitude.toStringAsFixed(6)}'
                          : 'Waiting for the other participant to open Share Live Location and grant GPS permission. The map will not use a fake/static marker.',
                    ),
                    if (locationError != null)
                      Text(
                        locationError!,
                        style: const TextStyle(color: AppColors.danger),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class DonorTrackingPage extends StatelessWidget {
  final String requestId;
  final String donorId;
  final double? patientLatitude;
  final double? patientLongitude;

  const DonorTrackingPage({
    super.key,
    required this.requestId,
    required this.donorId,
    this.patientLatitude,
    this.patientLongitude,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Live Patient & Donor Tracking')),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('blood_requests')
            .doc(requestId)
            .snapshots(),
        builder: (context, requestSnapshot) {
          final request = requestSnapshot.data?.data();
          final patientId = (request?['patientId'] ?? request?['createdBy'])
              ?.toString();
          return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance
                .collection('blood_requests')
                .doc(requestId)
                .collection('live_locations')
                .doc(donorId)
                .snapshots(),
            builder: (context, donorSnapshot) {
              return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                stream: patientId == null
                    ? null
                    : FirebaseFirestore.instance
                          .collection('blood_requests')
                          .doc(requestId)
                          .collection('live_locations')
                          .doc(patientId)
                          .snapshots(),
                builder: (context, patientSnapshot) {
                  final donorData = donorSnapshot.data?.data();
                  final patientData = patientSnapshot.data?.data();
                  final donorActive =
                      donorData?['active'] == true &&
                      donorData?['requestId']?.toString() == requestId;
                  final patientActive =
                      patientData?['active'] == true &&
                      patientData?['requestId']?.toString() == requestId;
                  final dlat = donorActive
                      ? (donorData?['latitude'] as num?)?.toDouble()
                      : null;
                  final dlon = donorActive
                      ? (donorData?['longitude'] as num?)?.toDouble()
                      : null;
                  final plat = patientActive
                      ? (patientData?['latitude'] as num?)?.toDouble()
                      : null;
                  final plon = patientActive
                      ? (patientData?['longitude'] as num?)?.toDouble()
                      : null;
                  final donor = dlat == null || dlon == null
                      ? null
                      : LatLng(dlat, dlon);
                  final patient = plat == null || plon == null
                      ? null
                      : LatLng(plat, plon);
                  final requestLat = (request?['patientLatitude'] as num?)
                      ?.toDouble();
                  final requestLon = (request?['patientLongitude'] as num?)
                      ?.toDouble();
                  final hospital = requestLat == null || requestLon == null
                      ? null
                      : LatLng(requestLat, requestLon);
                  final center =
                      donor ??
                      patient ??
                      hospital ??
                      const LatLng(13.0827, 80.2707);
                  final markers = <Marker>[
                    if (hospital != null)
                      Marker(
                        point: hospital,
                        width: 70,
                        height: 70,
                        child: const Icon(
                          Icons.local_hospital,
                          color: Colors.deepOrange,
                          size: 46,
                        ),
                      ),
                    if (patient != null)
                      Marker(
                        point: patient,
                        width: 70,
                        height: 70,
                        child: const Icon(
                          Icons.person_pin_circle,
                          color: AppColors.primary,
                          size: 48,
                        ),
                      ),
                    if (donor != null)
                      Marker(
                        point: donor,
                        width: 70,
                        height: 70,
                        child: const Icon(
                          Icons.my_location,
                          color: Colors.blue,
                          size: 44,
                        ),
                      ),
                  ];
                  return Column(
                    children: [
                      Expanded(
                        child: FlutterMap(
                          options: MapOptions(
                            initialCenter: center,
                            initialZoom: 13,
                            keepAlive: true,
                            backgroundColor: const Color(0xFFE8EEF2),
                          ),
                          children: [
                            TileLayer(
                              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                              userAgentPackageName: 'com.lifelink.ai',
                              maxZoom: 19,
                              errorTileCallback: (tile, error, stackTrace) {
                                debugPrint('OpenStreetMap tile error: $error');
                              },
                            ),
                            MarkerLayer(markers: markers),
                            RichAttributionWidget(
                              attributions: [
                                TextSourceAttribution(
                                  '© OpenStreetMap contributors',
                                  onTap: () => launchUrl(
                                    Uri.parse(
                                      'https://www.openstreetmap.org/copyright',
                                    ),
                                    mode: LaunchMode.externalApplication,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              donor == null
                                  ? 'Donor: waiting for live GPS sharing'
                                  : 'Donor GPS: ${donor.latitude.toStringAsFixed(6)}, ${donor.longitude.toStringAsFixed(6)}',
                            ),
                            const SizedBox(height: 6),
                            Text(
                              patient == null
                                  ? 'Patient: waiting for live GPS sharing'
                                  : 'Patient GPS: ${patient.latitude.toStringAsFixed(6)}, ${patient.longitude.toStringAsFixed(6)}',
                            ),
                            const SizedBox(height: 10),
                            const Text(
                              'Orange = saved hospital location; blue = donor live GPS; red = patient live GPS. The hospital pin is the saved hospital coordinate, not a live GPS marker. Both participants must grant location permission to share live GPS.',
                            ),
                            const SizedBox(height: 10),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                onPressed: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => DonorLiveLocationPage(
                                        requestId: requestId,
                                        patientLatitude: patient?.latitude ?? 0,
                                        patientLongitude:
                                            patient?.longitude ?? 0,
                                      ),
                                    ),
                                  );
                                },
                                icon: const Icon(Icons.my_location),
                                label: const Text('Share My Live Location'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

// ============================================================
// HOSPITAL AUTOCOMPLETE
// ============================================================

class HospitalSearchField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final Color iconColor;

  const HospitalSearchField({
    super.key,
    required this.controller,
    required this.label,
    required this.hint,
    this.iconColor = AppColors.primary,
  });

  @override
  Widget build(BuildContext context) {
    return Autocomplete<String>(
      initialValue: TextEditingValue(text: controller.text),
      optionsBuilder: (TextEditingValue textEditingValue) {
        final query = textEditingValue.text.trim().toLowerCase();

        if (query.isEmpty) {
          return hospitalNames;
        }

        return hospitalNames.where(
          (hospital) => hospital.toLowerCase().startsWith(query),
        );
      },
      onSelected: (String selection) {
        controller.text = selection;
      },
      fieldViewBuilder:
          (context, textEditingController, focusNode, onFieldSubmitted) {
            if (controller.text.isNotEmpty &&
                textEditingController.text.isEmpty) {
              textEditingController.text = controller.text;
            }

            return TextField(
              controller: textEditingController,
              focusNode: focusNode,
              onChanged: (value) {
                controller.value = textEditingController.value;
              },
              onSubmitted: (_) => onFieldSubmitted(),
              decoration: InputDecoration(
                labelText: label,
                hintText: hint,
                prefixIcon: Icon(Icons.local_hospital, color: iconColor),
              ),
            );
          },
      optionsViewBuilder: (context, onSelected, options) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 250, maxWidth: 500),
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                shrinkWrap: true,
                itemCount: options.length,
                itemBuilder: (context, index) {
                  final hospital = options.elementAt(index);
                  return ListTile(
                    leading: Icon(Icons.local_hospital, color: iconColor),
                    title: Text(hospital),
                    onTap: () => onSelected(hospital),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

// ============================================================
// HOSPITAL HOME DASHBOARD
// ============================================================

class HospitalDashboardPage extends StatelessWidget {
  const HospitalDashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('LifeLink'),
        actions: [
          IconButton(
            tooltip: 'Notifications',
            icon: const Icon(Icons.notifications_none),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const NotificationsPage()),
            ),
          ),
          IconButton(
            tooltip: 'Profile',
            icon: const Icon(Icons.person_outline),
            onPressed: () => showAccountMenu(context, 'Hospital'),
          ),
        ],
      ),
      bottomNavigationBar: const RoleBottomNav(
        role: 'Hospital',
        currentIndex: 0,
      ),
      body: const SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(18, 18, 18, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RoleProfileLabel(role: 'Hospital'),
            UserGreeting(
              role: 'Hospital',
              subtitle: 'Coordinate blood requests and priority donors.',
            ),
            SizedBox(height: 20),
            _MinimalDashboardCard(
              icon: Icons.local_hospital_outlined,
              title: 'Hospital Dashboard',
              subtitle: 'Use Requests for blood requirements and Donors for priority-based donor search.',
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// HOSPITAL MODULE (REQUESTS)
// ============================================================

class HospitalPage extends StatefulWidget {
  final int currentIndex;

  const HospitalPage({super.key, this.currentIndex = 1});

  @override
  State<HospitalPage> createState() => _HospitalPageState();
}

class _HospitalPageState extends State<HospitalPage> {
  String selectedBloodGroup = 'O+';
  bool savingRequest = false;
  int unitsRequired = 1;
  bool emergency = true;

  final TextEditingController patientController = TextEditingController();
  final TextEditingController hospitalController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadHospitalProfileAndRequest();
  }

  Future<void> _loadHospitalProfileAndRequest() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final profile = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      final allData = profile.data() ?? {};
      final rawProfiles = allData['roleProfiles'];
      final rawHospital = rawProfiles is Map ? rawProfiles['Hospital'] : null;
      final data = rawHospital is Map
          ? Map<String, dynamic>.from(rawHospital)
          : allData;
      hospitalController.text = data['name']?.toString() ?? '';
      await refreshActiveBloodRequest(ownerId: user.uid);
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> createBloodRequest() async {
    if (patientController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter patient name or ID')),
      );
      return;
    }

    if (hospitalController.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Please select a hospital')));
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Please login again.')));
      return;
    }

    setState(() => savingRequest = true);
    try {
      final hospitalProfile = await getRoleProfile('Hospital');
      // Prefer the coordinates for the selected hospital name. Older app
      // versions may have mistakenly stored the phone GPS in the hospital
      // profile, so blindly trusting those values can put the hospital pin
      // at the user's current location.
      final knownHospital = coordinatesForHospital(hospitalController.text);
      double? requestLat =
          knownHospital?.latitude ??
          (hospitalProfile['latitude'] as num?)?.toDouble();
      double? requestLon =
          knownHospital?.longitude ??
          (hospitalProfile['longitude'] as num?)?.toDouble();

      if (requestLat == null || requestLon == null) {
        if (knownHospital != null) {
          requestLat = knownHospital.latitude;
          requestLon = knownHospital.longitude;
          await updateRoleProfileFields('Hospital', {
            'latitude': requestLat,
            'longitude': requestLon,
            'locationUpdatedAt': FieldValue.serverTimestamp(),
          });
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Exact hospital coordinates are missing. Please set the hospital latitude and longitude in the Hospital profile before creating this request. Device GPS will not be used as the hospital location.',
                ),
                duration: Duration(seconds: 5),
              ),
            );
          }
          return;
        }
      }

      final ref = await FirebaseFirestore.instance
          .collection('blood_requests')
          .add({
            'patientId': null,
            'patientName': patientController.text.trim(),
            'bloodGroup': selectedBloodGroup,
            'units': unitsRequired,
            'hospital': hospitalController.text.trim(),
            'emergency': emergency,
            'status': 'Pending',
            'createdBy': user.uid,
            'patientLatitude': requestLat,
            'patientLongitude': requestLon,
            'createdAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
          });
      await notifyMatchingDonors(
        requestId: ref.id,
        bloodGroup: selectedBloodGroup,
      );
      final doc = await ref.get();
      activeBloodRequest = BloodRequest.fromDoc(doc);
      activeBloodRequestId = ref.id;
      if (mounted) setState(() {});

      // Best-effort notification delivery to exact blood-group donors.
      // Existing Firebase security rules are not changed.
      try {
        final donorSnapshot = await FirebaseFirestore.instance
            .collection('users')
            .get();

        final batch = FirebaseFirestore.instance.batch();

        for (final donorDoc in donorSnapshot.docs) {
          final rawProfiles = donorDoc.data()['roleProfiles'];
          final rawDonor = rawProfiles is Map ? rawProfiles['Donor'] : null;
          final donorProfile = rawDonor is Map
              ? Map<String, dynamic>.from(rawDonor)
              : <String, dynamic>{};
          final donorGroup =
              donorProfile['bloodGroup']?.toString().trim().toUpperCase() ?? '';
          if (donorGroup != selectedBloodGroup.trim().toUpperCase()) continue;
          if (donorProfile['available'] == false) continue;

          final notificationRef = FirebaseFirestore.instance
              .collection('notifications')
              .doc();

          batch.set(notificationRef, {
            'userId': donorDoc.id,
            'senderId': user.uid,
            'requestId': ref.id,
            'bloodGroup': selectedBloodGroup,
            'title': emergency ? 'Emergency blood request' : 'Blood request',
            'message':
                '${patientController.text.trim()} needs $selectedBloodGroup blood at ${hospitalController.text.trim()}.',
            'read': false,
            'createdAt': FieldValue.serverTimestamp(),
          });
        }

        await batch.commit();
      } catch (_) {
        // Keep the request working if the existing Firebase rules reject
        // this additional notification write.
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Blood request created successfully.')),
      );
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Unable to create request: $e')));
    } finally {
      if (mounted) setState(() => savingRequest = false);
    }
  }

  Future<void> cancelRequest() async {
    try {
      await updateBloodRequestStatus('Cancelled');
      activeBloodRequest = null;
      activeBloodRequestId = null;
      if (mounted) setState(() {});
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Blood request cancelled.')));
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Unable to cancel request: $e')));
    }
  }

  @override
  void dispose() {
    patientController.dispose();
    hospitalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final request = activeBloodRequest;

    return Scaffold(
      appBar: AppBar(
        title: const Text('LifeLink'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.notifications_none),
            tooltip: 'Notifications',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const NotificationsPage()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.person_outline),
            tooltip: 'Account',
            onPressed: () => showAccountMenu(context, 'Hospital'),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const UserGreeting(
              role: 'Hospital',
              subtitle: 'Create and monitor emergency blood requests.',
            ),
            const SizedBox(height: 20),

            Row(
              children: [
                Expanded(
                  child: _roleHomeActionCard(
                    context,
                    Icons.history_outlined,
                    'History',
                    () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const RoleHistoryPage(role: 'Hospital'),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _roleHomeActionCard(
                    context,
                    Icons.account_balance_outlined,
                    'Blood Bank',
                    () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const BloodBankDirectoryPage(),
                      ),
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 20),

            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Row(
                children: [
                  CircleAvatar(
                    radius: 30,
                    backgroundColor: AppColors.primary,
                    child: Icon(
                      Icons.local_hospital,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                  SizedBox(width: 15),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Hospital Account',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(height: 5),
                        Text(
                          'Hospital account',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.verified, color: AppColors.primary),
                ],
              ),
            ),

            const SizedBox(height: 20),

            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    backgroundColor: request == null
                        ? const Color(0xFFFFF3E0)
                        : AppColors.softTeal,
                    child: Icon(
                      request == null ? Icons.hourglass_empty : Icons.bloodtype,
                      color: request == null
                          ? Colors.orange
                          : AppColors.primary,
                    ),
                  ),
                  const SizedBox(width: 15),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Current Request',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          request == null
                              ? 'No active blood request'
                              : 'Status: ${request.status}',
                          style: const TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 25),

            const Text(
              'Create Blood Request',
              style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 15),

            TextField(
              controller: patientController,
              decoration: const InputDecoration(
                labelText: 'Patient Name / ID',
                hintText: 'Enter patient name or ID',
                prefixIcon: Icon(Icons.person, color: AppColors.primary),
              ),
            ),

            const SizedBox(height: 15),

            HospitalSearchField(
              controller: hospitalController,
              label: 'Hospital Name',
              hint: 'Start typing hospital name',
              iconColor: AppColors.primary,
            ),

            const SizedBox(height: 15),

            bloodGroupDropdown(selectedBloodGroup, AppColors.primary, (value) {
              if (value != null) {
                setState(() => selectedBloodGroup = value);
              }
            }),

            const SizedBox(height: 15),

            unitsSelector(
              color: AppColors.primary,
              value: unitsRequired,
              onMinus: () {
                if (unitsRequired > 1) {
                  setState(() => unitsRequired--);
                }
              },
              onPlus: () {
                if (unitsRequired < 10) {
                  setState(() => unitsRequired++);
                }
              },
            ),

            const SizedBox(height: 15),

            emergencySwitch(
              value: emergency,
              color: AppColors.primary,
              onChanged: (value) {
                setState(() => emergency = value);
              },
            ),

            const SizedBox(height: 25),

            SizedBox(
              width: double.infinity,
              height: 55,
              child: ElevatedButton.icon(
                onPressed: createBloodRequest,
                icon: const Icon(Icons.send),
                label: const Text(
                  'Create Blood Request',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(15),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 25),

            const SizedBox(height: 25),

            if (request != null)
              SizedBox(
                width: double.infinity,
                height: 50,
                child: OutlinedButton.icon(
                  onPressed: cancelRequest,
                  icon: const Icon(Icons.cancel_outlined),
                  label: const Text('Cancel Active Request'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.primary,
                  ),
                ),
              ),

            const SizedBox(height: 25),

            const Text(
              'Request Details',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),

            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
              ),
              child: request == null
                  ? const Text(
                      'No active request.',
                      style: TextStyle(color: Colors.grey),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        hospitalInfoRow(
                          Icons.person,
                          'Patient',
                          request.patientName,
                        ),
                        const SizedBox(height: 12),
                        hospitalInfoRow(
                          Icons.bloodtype,
                          'Blood Group',
                          request.bloodGroup,
                        ),
                        const SizedBox(height: 12),
                        hospitalInfoRow(
                          Icons.inventory_2,
                          'Units',
                          '${request.units}',
                        ),
                        const SizedBox(height: 12),
                        hospitalInfoRow(
                          Icons.local_hospital,
                          'Hospital',
                          request.hospital,
                        ),
                        const SizedBox(height: 12),
                        hospitalInfoRow(
                          Icons.warning_amber,
                          'Emergency',
                          request.emergency ? 'Yes' : 'No',
                        ),
                        const SizedBox(height: 12),
                        hospitalInfoRow(
                          Icons.access_time,
                          'Status',
                          request.status,
                        ),
                      ],
                    ),
            ),
            const SizedBox(height: 22),
            const HospitalDonorPreview(),
          ],
        ),
      ),

      bottomNavigationBar: RoleBottomNav(role: 'Hospital', currentIndex: 0),
    );
  }

  Widget _roleHomeActionCard(
    BuildContext context,
    IconData icon,
    String title,
    VoidCallback onTap,
  ) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          height: 86,
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Icon(icon, color: AppColors.primary, size: 24),
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget hospitalInfoRow(IconData icon, String title, String value) {
    return Row(
      children: [
        Icon(icon, color: AppColors.primary),
        const SizedBox(width: 12),
        Text('$title:', style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(value, style: const TextStyle(color: Colors.grey)),
        ),
      ],
    );
  }
}

// A compact donor directory preview shown directly on the Hospital page.
// AB+ recipients can receive red cells from all ABO/Rh donor groups, so this
// query is used to list available donors without excluding any blood group.
class HospitalDonorPreview extends StatefulWidget {
  const HospitalDonorPreview({super.key});

  @override
  State<HospitalDonorPreview> createState() => _HospitalDonorPreviewState();
}

class _HospitalDonorPreviewState extends State<HospitalDonorPreview> {
  late Future<List<Donor>> _donorsFuture;

  @override
  void initState() {
    super.initState();
    _donorsFuture = _loadDonors();
  }

  Future<List<Donor>> _loadDonors() {
    return fetchPriorityDonors(bloodGroup: 'AB+', radiusKm: 100000);
  }

  void _refresh() {
    setState(() => _donorsFuture = _loadDonors());
  }

  @override
  Widget build(BuildContext context) {
    final textColor = Theme.of(context).colorScheme.onSurface;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Available Donors',
                style: TextStyle(
                  color: textColor,
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Refresh donor list',
              onPressed: _refresh,
              icon: const Icon(Icons.refresh),
            ),
            TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const NearbyDonorsPage(role: 'Hospital'),
                ),
              ),
              child: const Text('View all'),
            ),
          ],
        ),
        Text(
          'Available registered and sample donors. Confirm compatibility clinically before transfusion.',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 10),
        FutureBuilder<List<Donor>>(
          future: _donorsFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.all(20),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Could not load donors. Check connection and Firebase permissions.',
                  ),
                ),
              );
            }
            final donors = snapshot.data ?? const <Donor>[];
            if (donors.isEmpty) {
              return const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'No available donors found yet. Registered donors who enable availability will appear here.',
                  ),
                ),
              );
            }
            final shown = donors.take(5).toList();
            return Column(
              children: [
                ...List.generate(shown.length, (i) {
                  final donor = shown[i];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _DonorDirectoryCard(
                      donor: donor,
                      priority: i < 3,
                      rank: i + 1,
                      distanceKm: double.nan,
                      requestRole: 'Hospital',
                    ),
                  );
                }),
              ],
            );
          },
        ),
      ],
    );
  }
}

// ============================================================
// ROLE-SPECIFIC ORGANIZATION DIRECTORIES
// ============================================================

class BloodBankDirectoryPage extends StatelessWidget {
  const BloodBankDirectoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return _OrganizationDirectoryPage(
      title: 'Blood Banks',
      role: 'Blood Bank',
      icon: Icons.bloodtype_outlined,
      subtitle: 'Find registered blood banks and their contact details.',
    );
  }
}

class HospitalsDirectoryPage extends StatelessWidget {
  const HospitalsDirectoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return _OrganizationDirectoryPage(
      title: 'Hospitals',
      role: 'Hospital',
      icon: Icons.local_hospital_outlined,
      subtitle: 'View registered hospitals and their contact details.',
    );
  }
}

class _OrganizationDirectoryPage extends StatelessWidget {
  final String title;
  final String role;
  final IconData icon;
  final String subtitle;

  const _OrganizationDirectoryPage({
    required this.title,
    required this.role,
    required this.icon,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final stream = FirebaseFirestore.instance
        .collection('users')
        .where('role', isEqualTo: role)
        .snapshots();

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: stream,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return _EmptyFeatureState(
              icon: Icons.error_outline,
              title: 'Unable to load $title',
              message: 'Please try again later.',
            );
          }

          final docs = snapshot.data?.docs ?? [];

          if (docs.isEmpty) {
            return _EmptyFeatureState(
              icon: icon,
              title: 'No registered $title',
              message: subtitle,
            );
          }

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.softTeal,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Row(
                  children: [
                    Icon(icon, color: AppColors.primary, size: 30),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        subtitle,
                        style: const TextStyle(
                          color: AppColors.navy,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              ...docs.map((doc) {
                final data = doc.data();
                final name = data['name']?.toString().trim().isNotEmpty == true
                    ? data['name'].toString()
                    : title.substring(0, title.length - 1);

                final phone = data['phone']?.toString() ?? '';
                final address = data['address']?.toString() ?? '';
                final contact = data['contactPerson']?.toString() ?? '';

                return Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: ListTile(
                    contentPadding: const EdgeInsets.all(14),
                    leading: CircleAvatar(
                      backgroundColor: AppColors.softTeal,
                      child: Icon(icon, color: AppColors.primary),
                    ),
                    title: Text(
                      name,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        [
                          if (contact.isNotEmpty) contact,
                          if (phone.isNotEmpty) phone,
                          if (address.isNotEmpty) address,
                        ].join(' • '),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    trailing: phone.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Call',
                            icon: const Icon(Icons.phone_outlined),
                            onPressed: () async {
                              final uri = Uri.parse('tel:$phone');
                              if (await canLaunchUrl(uri)) {
                                await launchUrl(uri);
                              }
                            },
                          ),
                  ),
                );
              }),
            ],
          );
        },
      ),
    );
  }
}

// ============================================================
// BLOOD BANK
// ============================================================

class BloodBankPage extends StatefulWidget {
  final int currentIndex;

  const BloodBankPage({super.key, this.currentIndex = 0});

  @override
  State<BloodBankPage> createState() => _BloodBankPageState();
}

class _BloodBankPageState extends State<BloodBankPage> {
  final Map<String, int> inventory = {
    'A+': 0,
    'A-': 0,
    'B+': 0,
    'B-': 0,
    'AB+': 0,
    'AB-': 0,
    'O+': 0,
    'O-': 0,
  };

  String selectedBloodGroup = 'A+';
  final TextEditingController unitsController = TextEditingController();

  final Set<String> requestedDonorNames = <String>{};
  List<Donor> previousDonorsForSelectedGroup = [];
  bool loadingDonors = true;
  bool loadingInventory = true;

  @override
  void initState() {
    super.initState();
    _loadBloodBankData();
  }

  Future<void> _loadBloodBankData() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final inventoryDoc = await FirebaseFirestore.instance
          .collection('blood_banks')
          .doc(user.uid)
          .get();
      final data = inventoryDoc.data() ?? {};
      final storedInventory = data['inventory'];
      if (storedInventory is Map) {
        for (final group in allBloodGroups) {
          final value = storedInventory[group];
          if (value is num) inventory[group] = value.toInt();
        }
      }
      await refreshActiveBloodRequest(pendingOnly: true);
      await _loadPreviousDonors();
    } catch (_) {}
    if (mounted) {
      setState(() {
        loadingInventory = false;
      });
    }
  }

  Future<void> _loadPreviousDonors() async {
    if (mounted) setState(() => loadingDonors = true);
    final donors = await fetchDonorsForBloodGroup(selectedBloodGroup);
    if (mounted) {
      setState(() {
        previousDonorsForSelectedGroup = donors;
        loadingDonors = false;
      });
    }
  }

  Future<void> _saveInventory() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    await FirebaseFirestore.instance
        .collection('blood_banks')
        .doc(user.uid)
        .set({
          'uid': user.uid,
          'inventory': inventory,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
  }

  void requestPreviousDonor(Donor donor) {
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.bloodtype, color: AppColors.primary),
              SizedBox(width: 8),
              Expanded(child: Text('Request Blood Donation')),
            ],
          ),
          content: Text(
            'Send this message to ${donor.name}?\n\n'
            '"LifeLink Blood Bank requests you to donate '
            '${donor.bloodGroup} blood. Your previous donations have '
            'helped patients in need. Please respond if you are available '
            'to donate."',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                if (donor.id == null) return;
                try {
                  await FirebaseFirestore.instance.collection('notifications').add({
                    'userId': donor.id,
                    'title': 'Blood donation request',
                    'message':
                        'LifeLink Blood Bank is requesting ${donor.bloodGroup} blood. Please respond if you are available.',
                    'read': false,
                    'createdAt': FieldValue.serverTimestamp(),
                  });
                  if (mounted) {
                    setState(() => requestedDonorNames.add(donor.id!));
                  }
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Donation request sent to ${donor.name}.',
                        ),
                      ),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Unable to send request: $e')),
                    );
                  }
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
              ),
              child: const Text('Send Request'),
            ),
          ],
        );
      },
    );
  }

  Future<void> addUnits() async {
    final units = int.tryParse(unitsController.text.trim());

    if (units == null || units <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid number of units')),
      );
      return;
    }

    setState(() {
      inventory[selectedBloodGroup] =
          (inventory[selectedBloodGroup] ?? 0) + units;
      unitsController.clear();
    });
    try {
      await _saveInventory();
    } catch (_) {}

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '$units unit${units > 1 ? 's' : ''} added to $selectedBloodGroup',
        ),
      ),
    );
  }

  Future<void> removeUnits() async {
    final units = int.tryParse(unitsController.text.trim());

    if (units == null || units <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid number of units')),
      );
      return;
    }

    final current = inventory[selectedBloodGroup] ?? 0;

    if (units > current) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not enough units in inventory')),
      );
      return;
    }

    setState(() {
      inventory[selectedBloodGroup] = current - units;
      unitsController.clear();
    });
    try {
      await _saveInventory();
    } catch (_) {}

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '$units unit${units > 1 ? 's' : ''} removed from $selectedBloodGroup',
        ),
      ),
    );
  }

  int get totalUnits =>
      inventory.values.fold(0, (total, value) => total + value);

  int get lowStockCount => inventory.values.where((value) => value <= 5).length;

  @override
  void dispose() {
    unitsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'LifeLink',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.notifications_none),
            tooltip: 'Notifications',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const NotificationsPage()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.person_outline),
            tooltip: 'Account',
            onPressed: () => showAccountMenu(context, 'Blood Bank'),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 30),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.currentIndex == 0) ...[
              const RoleProfileLabel(role: 'Blood Bank'),
              const UserGreeting(
                role: 'Blood Bank',
                subtitle: 'Manage blood inventory and donor coordination.',
              ),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [AppColors.softTeal, Colors.white],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(
                    color: AppColors.primary.withValues(alpha: 0.10),
                  ),
                ),
                child: const Row(
                  children: [
                    CircleAvatar(
                      radius: 28,
                      backgroundColor: AppColors.primary,
                      child: Icon(
                        Icons.bloodtype,
                        color: Colors.white,
                        size: 30,
                      ),
                    ),
                    SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Blood Bank Dashboard',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          SizedBox(height: 5),
                          Text(
                            'Blood bank overview and stock status.',
                            style: TextStyle(color: Colors.grey, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: _bloodBankSummaryCard(
                      Icons.bloodtype,
                      'Total Units',
                      '$totalUnits',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _bloodBankSummaryCard(
                      Icons.warning_amber_rounded,
                      'Low Stock',
                      '$lowStockCount',
                    ),
                  ),
                ],
              ),
            ] else if (widget.currentIndex == 1) ...[
              const RoleProfileLabel(role: 'Blood Bank'),
              const Text(
                'Inventory',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 5),
              Text(
                'Manage blood units and view previous donors.',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
              ),
              const SizedBox(height: 14),
              const Text(
                'Blood Inventory',
                style: TextStyle(fontSize: 23, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 5),
              Text(
                'Select a blood group to view its previous donors.',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
              ),
              const SizedBox(height: 14),

              // Inventory cards. No Spacer/fixed-height content, so there
              // are no yellow/black overflow warnings.
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: inventory.length,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  childAspectRatio: 1.12,
                ),
                itemBuilder: (context, index) {
                  final entry = inventory.entries.elementAt(index);
                  final group = entry.key;
                  final units = entry.value;
                  final isLow = units <= 5;
                  final isSelected = selectedBloodGroup == group;

                  return Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: () async {
                        setState(() => selectedBloodGroup = group);
                        await _loadPreviousDonors();
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        padding: const EdgeInsets.all(15),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: isSelected
                                ? AppColors.primary
                                : isLow
                                ? Colors.orange
                                : Colors.grey.shade200,
                            width: isSelected ? 2 : 1,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.04),
                              blurRadius: 8,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 38,
                                  height: 38,
                                  decoration: const BoxDecoration(
                                    color: AppColors.softTeal,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.bloodtype,
                                    color: AppColors.primary,
                                    size: 23,
                                  ),
                                ),
                                const SizedBox(width: 9),
                                Expanded(
                                  child: Text(
                                    group,
                                    style: const TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                if (isSelected)
                                  const Icon(
                                    Icons.check_circle,
                                    color: AppColors.primary,
                                    size: 19,
                                  ),
                              ],
                            ),
                            const Spacer(),
                            Text(
                              '$units units',
                              style: const TextStyle(
                                fontSize: 21,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              isLow ? 'Low stock' : 'Available',
                              style: TextStyle(
                                color: isLow ? Colors.orange : Colors.green,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              isSelected
                                  ? 'Selected • view donors below'
                                  : 'Tap to select',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppColors.primary,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),

              const SizedBox(height: 26),

              _sectionTitle(
                'Update Inventory',
                'Add or remove units safely',
                Icons.inventory_2_outlined,
              ),
              const SizedBox(height: 12),

              Container(
                padding: const EdgeInsets.all(17),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: Column(
                  children: [
                    bloodGroupDropdown(selectedBloodGroup, AppColors.primary, (
                      value,
                    ) {
                      if (value != null) {
                        setState(() => selectedBloodGroup = value);
                      }
                    }),
                    const SizedBox(height: 14),
                    TextField(
                      controller: unitsController,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: 'Number of Units',
                        prefixIcon: const Icon(
                          Icons.numbers,
                          color: AppColors.primary,
                        ),
                        filled: true,
                        fillColor: const Color(0xFFF8F8F8),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: SizedBox(
                            height: 48,
                            child: ElevatedButton.icon(
                              onPressed: addUnits,
                              icon: const Icon(Icons.add),
                              label: const Text('Add Units'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.primary,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: SizedBox(
                            height: 48,
                            child: OutlinedButton.icon(
                              onPressed: removeUnits,
                              icon: const Icon(Icons.remove),
                              label: const Text('Remove'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.primary,
                                side: const BorderSide(
                                  color: AppColors.primary,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),
            ],
          ],
        ),
      ),

      bottomNavigationBar: RoleBottomNav(
        role: 'Blood Bank',
        currentIndex: widget.currentIndex,
      ),
    );
  }

  Widget _bloodBankHomeActionCard(
    BuildContext context,
    IconData icon,
    String title,
    VoidCallback onTap,
  ) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          width: double.infinity,
          height: 86,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: const BoxDecoration(
                  color: AppColors.softTeal,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: AppColors.primary, size: 23),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              ),
              const Icon(Icons.chevron_right, color: AppColors.mutedText),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bloodBankSummaryCard(IconData icon, String title, String value) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: const BoxDecoration(
              color: AppColors.softTeal,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: AppColors.primary, size: 23),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title, String subtitle, IconData icon) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: const BoxDecoration(
            color: AppColors.softTeal,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: AppColors.primary, size: 22),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                subtitle,
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget summaryCard(IconData icon, String title, String value) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: AppColors.primary, size: 30),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          Text(title, style: const TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }
}

class PatientDashboardPage extends StatelessWidget {
  const PatientDashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('LifeLink'),
        actions: [
          IconButton(
            tooltip: 'Notifications',
            icon: const Icon(Icons.notifications_none),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const NotificationsPage()),
            ),
          ),
          IconButton(
            tooltip: 'Profile',
            icon: const Icon(Icons.person_outline),
            onPressed: () => showAccountMenu(context, 'Patient'),
          ),
        ],
      ),
      bottomNavigationBar: const RoleBottomNav(
        role: 'Patient',
        currentIndex: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const RoleProfileLabel(role: 'Patient'),
            const UserGreeting(
              role: 'Patient',
              subtitle: 'Create a blood request and find priority donors when needed.',
            ),
            const SizedBox(height: 20),
            const _MinimalDashboardCard(
              icon: Icons.health_and_safety_outlined,
              title: 'Patient Dashboard',
              subtitle: 'Find compatible donors ranked by blood group, availability and distance.',
            ),
            const SizedBox(height: 16),
            const _PriorityDonorSearchCard(),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: _DashboardActionTile(
                    icon: Icons.add_circle_outline_rounded,
                    title: 'Create Request',
                    subtitle: 'Request blood',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const PatientPage()),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _DashboardActionTile(
                    icon: Icons.list_alt_rounded,
                    title: 'My Requests',
                    subtitle: 'Track status',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            const BloodRequestsListPage(scope: 'currentUser'),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PriorityDonorSearchCard extends StatelessWidget {
  const _PriorityDonorSearchCard();

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final foreground = Theme.of(context).colorScheme.onSurface;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? const [Color(0xFF49222D), Color(0xFF2A1B21)]
              : const [Color(0xFFFFE8ED), Color(0xFFFFF7F8)],
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: dark ? const Color(0xFF75404D) : AppColors.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: dark ? const Color(0xFF5B2937) : Colors.white,
                  borderRadius: BorderRadius.circular(15),
                ),
                child: const Icon(
                  Icons.manage_search_rounded,
                  color: AppColors.primary,
                  size: 29,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Priority-based donor search',
                  style: TextStyle(
                    color: foreground,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Find potential donors ranked by blood-group compatibility and proximity. Filter by blood group, city and search radius.',
            style: TextStyle(
              color: dark ? const Color(0xFFE9D9DE) : AppColors.mutedText,
              height: 1.4,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 15),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              icon: const Icon(Icons.search_rounded),
              label: const Text('Find Priority Donors'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const NearbyDonorsPage(role: 'Patient'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DashboardActionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _DashboardActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final text = Theme.of(context).colorScheme.onSurface;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: dark ? const Color(0xFF4A3038) : AppColors.border,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: AppColors.primary, size: 26),
              const SizedBox(height: 10),
              Text(
                title,
                style: TextStyle(color: text, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 3),
              Text(
                subtitle,
                style: TextStyle(
                  color: dark ? const Color(0xFFD7C5CB) : AppColors.mutedText,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MinimalDashboardCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _MinimalDashboardCard({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final surface = Theme.of(context).colorScheme.surface;
    final text = Theme.of(context).colorScheme.onSurface;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: dark ? const Color(0xFF63313D) : AppColors.border,
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: dark ? 0.10 : 0.07),
            blurRadius: 18,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  color: dark
                      ? const Color(0xFF42232D)
                      : const Color(0xFFFFE5EA),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Icon(icon, color: AppColors.primary, size: 29),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: text,
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const LifeLinkMascot(compact: true),
            ],
          ),
          const SizedBox(height: 13),
          Text(
            subtitle,
            style: TextStyle(
              color: dark ? const Color(0xFFE0D0D5) : AppColors.mutedText,
              fontSize: 14,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: dark ? const Color(0xFF352029) : const Color(0xFFFFF0F3),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.favorite_rounded,
                  color: AppColors.primary,
                  size: 17,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Every donation can make a difference.',
                    style: TextStyle(
                      color: dark
                          ? const Color(0xFFFFDDE5)
                          : AppColors.primaryDark,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
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

class PatientPage extends StatefulWidget {
  const PatientPage({super.key});

  @override
  State<PatientPage> createState() => _PatientPageState();
}

class _PatientPageState extends State<PatientPage> {
  String selectedBloodGroup = 'O+';
  int unitsRequired = 1;
  bool emergency = true;
  bool submitting = false;
  bool loadingRequest = true;

  final TextEditingController patientController = TextEditingController();
  final TextEditingController hospitalController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadPatientData();
  }

  Future<void> _loadPatientData() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final profile = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      final allData = profile.data() ?? {};
      final rawProfiles = allData['roleProfiles'];
      final rawPatient = rawProfiles is Map ? rawProfiles['Patient'] : null;
      final data = rawPatient is Map
          ? Map<String, dynamic>.from(rawPatient)
          : allData;
      await refreshActiveBloodRequest(ownerId: user.uid);
      if (!mounted) return;
      setState(() {
        final storedName = data['name']?.toString().trim() ?? '';
        patientController.text = storedName.isNotEmpty
            ? storedName
            : (user.email?.split('@').first ?? 'Patient');
        selectedBloodGroup = data['bloodGroup']?.toString() ?? 'O+';
        loadingRequest = false;
      });
    } catch (_) {
      if (mounted) setState(() => loadingRequest = false);
    }
  }

  Future<void> submitRequest() async {
    if (patientController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter patient name')),
      );
      return;
    }

    if (hospitalController.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Please select a hospital')));
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Please login again.')));
      return;
    }

    setState(() => submitting = true);
    try {
      final patientProfile = await getRoleProfile('Patient');
      double? requestLat = (patientProfile['latitude'] as num?)?.toDouble();
      double? requestLon = (patientProfile['longitude'] as num?)?.toDouble();

      if (requestLat == null || requestLon == null) {
        final position = await getDeviceLocation();
        if (position == null) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Please enable location so donors can navigate to the exact patient place.',
                ),
              ),
            );
          }
          return;
        }
        requestLat = position.latitude;
        requestLon = position.longitude;
        await updateRoleProfileFields('Patient', {
          'latitude': requestLat,
          'longitude': requestLon,
          'locationUpdatedAt': FieldValue.serverTimestamp(),
        });
      }

      final ref = await FirebaseFirestore.instance
          .collection('blood_requests')
          .add({
            'patientId': user.uid,
            'patientName': patientController.text.trim(),
            'bloodGroup': selectedBloodGroup,
            'units': unitsRequired,
            'hospital': hospitalController.text.trim(),
            'emergency': emergency,
            'status': 'Pending',
            'createdBy': user.uid,
            'patientLatitude': requestLat,
            'patientLongitude': requestLon,
            'createdAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
          });
      await notifyMatchingDonors(
        requestId: ref.id,
        bloodGroup: selectedBloodGroup,
      );
      final doc = await ref.get();
      activeBloodRequest = BloodRequest.fromDoc(doc);
      activeBloodRequestId = ref.id;
      if (mounted) setState(() {});

      await showDialog<void>(
        context: context,
        builder: (_) {
          return AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.check_circle, color: Colors.green),
                SizedBox(width: 8),
                Expanded(child: Text('Request Submitted')),
              ],
            ),
            content: Text(
              'Your request has been saved and is now available to compatible donors.\n\n'
              'Blood Group: $selectedBloodGroup\n'
              'Units: $unitsRequired\n'
              'Hospital: ${hospitalController.text}\n'
              'Emergency: ${emergency ? "Yes" : "No"}',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          );
        },
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Unable to submit blood request: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => submitting = false);
    }
  }

  @override
  void dispose() {
    patientController.dispose();
    hospitalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final request = activeBloodRequest;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Request Blood'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.notifications_none),
            tooltip: 'Notifications',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const NotificationsPage()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.person_outline),
            tooltip: 'Account',
            onPressed: () => showAccountMenu(context, 'Patient'),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const UserGreeting(
              role: 'Patient',
              subtitle: 'Request blood quickly during an emergency.',
            ),
            const SizedBox(height: 20),

            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Row(
                children: [
                  Icon(Icons.emergency, color: AppColors.primary, size: 40),
                  SizedBox(width: 15),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Need Blood Urgently?',
                          style: TextStyle(
                            color: AppColors.primary,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(height: 5),
                        Text('Create a request and notify nearby donors.'),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 25),

            const Text(
              'Blood Request',
              style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 15),

            TextField(
              controller: patientController,
              decoration: const InputDecoration(
                labelText: 'Patient Name / ID',
                prefixIcon: Icon(Icons.person, color: AppColors.primary),
              ),
            ),

            const SizedBox(height: 15),

            bloodGroupDropdown(selectedBloodGroup, AppColors.primary, (value) {
              if (value != null) {
                setState(() => selectedBloodGroup = value);
              }
            }),

            const SizedBox(height: 15),

            unitsSelector(
              color: AppColors.primary,
              value: unitsRequired,
              onMinus: () {
                if (unitsRequired > 1) {
                  setState(() => unitsRequired--);
                }
              },
              onPlus: () {
                if (unitsRequired < 10) {
                  setState(() => unitsRequired++);
                }
              },
            ),

            const SizedBox(height: 15),

            HospitalSearchField(
              controller: hospitalController,
              label: 'Hospital / Medical Center',
              hint: 'Start typing hospital name',
              iconColor: AppColors.primary,
            ),

            const SizedBox(height: 15),

            emergencySwitch(
              value: emergency,
              color: AppColors.danger,
              onChanged: (value) {
                setState(() => emergency = value);
              },
            ),

            const SizedBox(height: 25),

            SizedBox(
              width: double.infinity,
              height: 55,
              child: ElevatedButton.icon(
                onPressed: submitting ? null : submitRequest,
                icon: submitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : const Icon(Icons.send),
                label: Text(
                  submitting ? 'Submitting...' : 'Submit Blood Request',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(15),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 30),

            const SizedBox(height: 18),

            if (request?.donorId != null)
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => DonorTrackingPage(
                          requestId: request!.id!,
                          donorId: request.donorId!,
                          patientLatitude: request.patientLatitude,
                          patientLongitude: request.patientLongitude,
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.location_searching),
                  label: const Text('Track Donor Live'),
                ),
              ),

            const SizedBox(height: 18),

            if (request?.donorId != null)
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => DonorTrackingPage(
                          requestId: request!.id!,
                          donorId: request.donorId!,
                          patientLatitude: request.patientLatitude,
                          patientLongitude: request.patientLongitude,
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.location_searching),
                  label: const Text('Track Donor Live'),
                ),
              ),

            const SizedBox(height: 30),

            const Text(
              'Request Status',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),

            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
              ),
              child: request == null
                  ? const Row(
                      children: [
                        CircleAvatar(
                          backgroundColor: Color(0xFFFFF3E0),
                          child: Icon(
                            Icons.hourglass_empty,
                            color: Colors.orange,
                          ),
                        ),
                        SizedBox(width: 15),
                        Expanded(
                          child: Text(
                            'No Active Request',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        CircleAvatar(
                          backgroundColor: request.status == 'Pending'
                              ? const Color(0xFFFFF3E0)
                              : const Color(0xFFE8F5E9),
                          child: Icon(
                            request.status == 'Pending'
                                ? Icons.hourglass_empty
                                : Icons.check_circle,
                            color: request.status == 'Pending'
                                ? Colors.orange
                                : Colors.green,
                          ),
                        ),
                        const SizedBox(width: 15),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Active Request',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Status: ${request.status}',
                                style: const TextStyle(color: Colors.grey),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
            ),
            const SizedBox(height: 30),
          ],
        ),
      ),

      bottomNavigationBar: RoleBottomNav(role: 'Patient', currentIndex: 1),
    );
  }
}

// ============================================================
// COMMON WIDGETS
// ============================================================

Widget bloodGroupDropdown(
  String selectedValue,
  Color iconColor,
  ValueChanged<String?> onChanged,
) {
  return Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: AppColors.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.bloodtype_outlined, color: iconColor, size: 20),
            const SizedBox(width: 8),
            const Text(
              'Blood Group',
              style: TextStyle(
                color: Color(0xFF333333),
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: allBloodGroups.map((group) {
            final selected = selectedValue == group;
            return ChoiceChip(
              label: Text(group),
              selected: selected,
              onSelected: (_) => onChanged(group),
              selectedColor: AppColors.primary,
              backgroundColor: AppColors.background,
              side: BorderSide(
                color: selected ? AppColors.primary : AppColors.border,
              ),
              labelStyle: TextStyle(
                color: selected ? Colors.white : AppColors.navy,
                fontWeight: FontWeight.w700,
              ),
            );
          }).toList(),
        ),
      ],
    ),
  );
}

Widget unitsSelector({
  required Color color,
  required int value,
  required VoidCallback onMinus,
  required VoidCallback onPlus,
}) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: AppColors.border),
    ),
    child: Row(
      children: [
        const Expanded(
          child: Text(
            'Units Required',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
        ),
        IconButton(
          onPressed: onMinus,
          icon: Icon(Icons.remove_circle_outline, color: color),
        ),
        SizedBox(
          width: 34,
          child: Text(
            '$value',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
        ),
        IconButton(
          onPressed: onPlus,
          icon: Icon(Icons.add_circle_outline, color: color),
        ),
      ],
    ),
  );
}

Widget emergencySwitch({
  required bool value,
  required Color color,
  required ValueChanged<bool> onChanged,
}) {
  return Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: value ? AppColors.danger.withValues(alpha: .06) : Colors.white,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(
        color: value
            ? AppColors.danger.withValues(alpha: .35)
            : AppColors.border,
      ),
    ),
    child: Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: value
                ? AppColors.danger.withValues(alpha: .12)
                : AppColors.background,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            Icons.priority_high_rounded,
            color: value ? AppColors.danger : AppColors.mutedText,
          ),
        ),
        const SizedBox(width: 12),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Emergency Request',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
              ),
              SizedBox(height: 3),
              Text(
                'Notify compatible donors immediately',
                style: TextStyle(color: AppColors.mutedText, fontSize: 12),
              ),
            ],
          ),
        ),
        Switch(
          value: value,
          activeColor: AppColors.danger,
          activeTrackColor: AppColors.danger,
          onChanged: onChanged,
        ),
      ],
    ),
  );
}

Widget emptyCard(IconData icon, String title, String subtitle) {
  return Container(
    width: double.infinity,
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
    ),
    child: Column(
      children: [
        Icon(icon, color: Colors.green, size: 50),
        const SizedBox(height: 10),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 5),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.grey),
        ),
      ],
    ),
  );
}
