import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_storage/firebase_storage.dart'; // Used by other existing features; bank documents use Supabase.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vibration/vibration.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;

import 'firebase_options.dart';

const orange = Color(0xFFFF6B35);
const orange2 = Color(0xFFFF9F43);
const yellow = Color(0xFFFFC107);
const green = Color(0xFF16A34A);
const blue = Color(0xFF2563EB);
const purple = Color(0xFF7C3AED);
const red = Color(0xFFEF4444);
const dark = Color(0xFF171717);
const grey = Color(0xFF707070);
const bg = Color(0xFFF6F7FB);

InputDecoration inputDecoration(String label, IconData icon, {Widget? suffix}) {
  return InputDecoration(
    labelText: label,
    prefixIcon: Icon(icon),
    suffixIcon: suffix,
    counterText: '',
    filled: true,
    fillColor: const Color(0xFFF8F8F8),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 17),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(15),
      borderSide: BorderSide.none,
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(15),
      borderSide: BorderSide.none,
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(15),
      borderSide: const BorderSide(color: orange, width: 2),
    ),
  );
}

final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();
final GlobalKey<ScaffoldMessengerState> appScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
}

class DeliveryNotificationService {
  static final FirebaseMessaging _messaging = FirebaseMessaging.instance;

  static Future<void> initialize() async {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    try {
      await _messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        announcement: false,
        carPlay: false,
        criticalAlert: false,
        provisional: false,
      );
    } catch (_) {
      // Notification permission is optional for app startup.
    }

    FirebaseAuth.instance.authStateChanges().listen((user) async {
      if (user == null) return;
      try {
        await _saveToken(await _messaging.getToken());
      } catch (_) {
        // Token may be unavailable on some devices/configurations.
      }
    });

    try {
      await _saveToken(await _messaging.getToken());
    } catch (_) {
      // Token may be unavailable on some devices/configurations.
    }

    _messaging.onTokenRefresh.listen((token) async {
      await _saveToken(token);
    });

    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      _showForegroundMessage(message);
    });

    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      _openFromNotification(message);
    });

    try {
      final initialMessage = await _messaging.getInitialMessage();
      if (initialMessage != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _openFromNotification(initialMessage);
        });
      }
    } catch (_) {
      // Ignore notification-open errors so login/app startup remains usable.
    }
  }

  static Future<void> _saveToken(String? token) async {
    if (token == null || token.trim().isEmpty) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    await FirebaseFirestore.instance
        .collection('deliveryPartners')
        .doc(user.uid)
        .set({
          'fcmToken': token,
          'fcmTokenUpdatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
  }

  static void _showForegroundMessage(RemoteMessage message) {
    final title =
        message.notification?.title ??
        message.data['title']?.toString() ??
        'FlashCart Delivery';

    final body =
        message.notification?.body ??
        message.data['body']?.toString() ??
        'आपके लिए नया notification है।';

    appScaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
            const SizedBox(height: 3),
            Text(body),
          ],
        ),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 5),
        action: SnackBarAction(
          label: 'OPEN',
          onPressed: () => _openFromNotification(message),
        ),
      ),
    );
  }

  static void _openFromNotification(RemoteMessage message) {
    final orderId = message.data['orderId']?.toString().trim() ?? '';
    final navigator = appNavigatorKey.currentState;

    if (navigator == null) return;

    navigator.push(
      MaterialPageRoute(builder: (_) => const DeliveryNotificationOpenPage()),
    );

    // The order ID is kept in the page so the partner can see which
    // notification was opened. The Orders tab remains the source of truth.
    if (orderId.isNotEmpty) {
      // No Firestore write is needed here; notification taps are read-only.
    }
  }
}

class DeliveryOrderAlertService {
  static Timer? _timer;
  static bool _running = false;

  static Future<void> start(String orderId) async {
    if (_running) return;
    _running = true;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 700), (timer) async {
      if (!_running || timer.tick > 22) {
        timer.cancel();
        _running = false;
        return;
      }
      try {
        if (await Vibration.hasVibrator()) {
          Vibration.vibrate(duration: 450);
        }
      } catch (_) {}
      try {
        await SystemSound.play(SystemSoundType.alert);
      } catch (_) {}
    });
  }

  static void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
  }
}

class DeliveryAnnouncementService {
  static StreamSubscription? _sub;
  static void initialize() {
    _sub?.cancel();
    _sub = FirebaseFirestore.instance
        .collection('adminNotifications')
        .where('published', isEqualTo: true)
        .snapshots()
        .listen((snapshot) {
          for (final change in snapshot.docChanges) {
            if (change.type != DocumentChangeType.added) continue;
            final x = change.doc.data();
            if (x == null) continue;
            final audience = (x['audience'] ?? 'all').toString();
            if (audience != 'all' && audience != 'partners') continue;
            appScaffoldMessengerKey.currentState?.showSnackBar(
              SnackBar(
                content: Text(
                  '${x['title'] ?? 'FlashCart'}\n${x['message'] ?? ''}',
                ),
                duration: const Duration(seconds: 6),
              ),
            );
          }
        });
  }
}

// ============================================================
// CLIENT-SIDE FIFO ORDER ASSIGNMENT (NO BLAZE REQUIRED)
// ============================================================
//
// This is the no-Cloud-Functions fallback. While a delivery partner is
// online, the app periodically checks the Firestore queue. Only the partner
// who is currently first in the online FIFO queue is allowed to claim the
// oldest unassigned order. A Firestore transaction re-checks the order and
// partner before writing, so two partner phones cannot intentionally claim the
// same order at the same time.
//
// This keeps the existing server-side fields compatible:
// deliveryPartnerId, deliveryPartnerName, deliveryPartnerPhone,
// assignmentStatus, assignedAt, updatedAt, availableForOrder,
// activeOrderId and lastAssignedAt.
class PartnerLocalNotificationService {
  static final FlutterLocalNotificationsPlugin plugin =
      FlutterLocalNotificationsPlugin();

  static Future<void> initialize() async {
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );
    await plugin.initialize(settings: settings);
    await plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
    const channel = AndroidNotificationChannel(
      'flashcart_partner_orders',
      'FlashCart Delivery Orders',
      description: 'New delivery order alerts',
      importance: Importance.max,
    );
    await plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(channel);
  }

  static Future<void> showOrderAlert(String orderId) async {
    await plugin.show(
      id: orderId.hashCode & 0x7fffffff,
      title: '🚚 New FlashCart Order',
      body: 'New delivery order $orderId is assigned to you.',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'flashcart_partner_orders',
          'FlashCart Delivery Orders',
          channelDescription: 'New delivery order alerts',
          importance: Importance.max,
          priority: Priority.max,
          playSound: true,
          enableVibration: true,
          category: AndroidNotificationCategory.call,
        ),
      ),
    );
  }

  static Future<void> showAnnouncement(String title, String body) async {
    await plugin.show(
      id: DateTime.now().millisecondsSinceEpoch.remainder(2147483647),
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'flashcart_partner_orders',
          'FlashCart Delivery Orders',
          channelDescription: 'New delivery order alerts',
          importance: Importance.high,
          priority: Priority.high,
          playSound: true,
        ),
      ),
    );
  }
}

// ============================================================
// APPROVED PARTNER PROFILE BOOTSTRAP
// ============================================================
// If Phone Auth succeeded but the partner document was created before the
// Firebase Auth UID was known, migrate the approved application/profile to the
// current Firebase UID. This makes the Orders query and FIFO assignment work
// without opening the Admin app.
class PartnerProfileBootstrap {
  static Future<void> ensure() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final db = FirebaseFirestore.instance;
    final uid = user.uid;
    final partnerRef = db.collection('deliveryPartners').doc(uid);

    try {
      final direct = await partnerRef.get();
      final phone = user.phoneNumber?.trim() ?? '';
      if (phone.isEmpty) return;

      // Read the approved application first so a UID-based profile that already
      // exists but has no branchId can be repaired without deleting/recreating
      // the partner account. Never overwrite a non-empty branch assignment.
      final approved = await db
          .collection('deliveryPartnerApplications')
          .where('phone', isEqualTo: phone)
          .where('status', isEqualTo: 'approved')
          .limit(1)
          .get();

      if (direct.exists) {
        final current = direct.data() ?? <String, dynamic>{};
        final currentBranchId =
            (current['branchId'] ?? current['storeId'] ?? '').toString().trim();
        if (currentBranchId.isNotEmpty) return;

        if (approved.docs.isNotEmpty) {
          final appDoc = approved.docs.first;
          final appData = appDoc.data();
          final branchId = (appData['branchId'] ?? appData['storeId'] ?? '')
              .toString()
              .trim();
          if (branchId.isNotEmpty) {
            final branchName =
                (appData['branchName'] ?? appData['storeName'] ?? '')
                    .toString()
                    .trim();
            await partnerRef.set({
              'branchId': branchId,
              'storeId': branchId,
              if (branchName.isNotEmpty) 'branchName': branchName,
              if (branchName.isNotEmpty) 'storeName': branchName,
              'applicationId': current['applicationId'] ?? appDoc.id,
              'authUid': uid,
              'updatedAt': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
          } else {
            debugPrint(
              'PARTNER_PROFILE_BOOTSTRAP: approved application has no branchId',
            );
          }
        } else {
          debugPrint(
            'PARTNER_PROFILE_BOOTSTRAP: existing profile has no branchId and no approved application found',
          );
        }
        return;
      }

      if (approved.docs.isNotEmpty) {
        final doc = approved.docs.first;
        final data = doc.data();
        await partnerRef.set({
          'name': data['name'] ?? data['fullName'] ?? 'Delivery Partner',
          'phone': phone,
          'mobile': data['mobile'] ?? phone.replaceFirst('+91', ''),
          'mobileNumber': data['mobileNumber'] ?? phone.replaceFirst('+91', ''),
          'vehicle': data['vehicle'] ?? '',
          'vehicleNumber': data['vehicleNumber'] ?? '',
          'area': data['area'] ?? '',
          'branchId': data['branchId'] ?? data['storeId'] ?? '',
          'storeId': data['storeId'] ?? data['branchId'] ?? '',
          'branchName': data['branchName'] ?? data['storeName'] ?? '',
          'storeName': data['storeName'] ?? data['branchName'] ?? '',
          'aadhaarNumber': data['aadhaarNumber'] ?? '',
          'aadhaarPhotoBase64': data['aadhaarPhotoBase64'] ?? '',
          'aadhaarPhotoName': data['aadhaarPhotoName'] ?? '',
          'active': true,
          'online': false,
          'availableForOrder': false,
          'authUid': uid,
          'applicationId': doc.id,
          'approvedAt': data['reviewedAt'] ?? FieldValue.serverTimestamp(),
          'createdAt': data['createdAt'] ?? FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        return;
      }

      // Compatibility with older Admin-approved partner documents that used
      // the application ID as the document ID.
      for (final field in ['phone', 'mobile', 'mobileNumber']) {
        final values = <String>{
          phone,
          phone.startsWith('+91') ? phone.substring(3) : phone,
        };
        for (final value in values) {
          try {
            final snap = await db
                .collection('deliveryPartners')
                .where(field, isEqualTo: value)
                .limit(1)
                .get();
            if (snap.docs.isEmpty) continue;
            final old = snap.docs.first;
            final data = Map<String, dynamic>.from(old.data());
            if (data['active'] == false) return;
            data['phone'] = phone;
            data['authUid'] = uid;
            data['applicationId'] = data['applicationId'] ?? old.id;
            data['migratedFrom'] = old.id;
            data['updatedAt'] = FieldValue.serverTimestamp();
            await partnerRef.set(data, SetOptions(merge: true));
            return;
          } catch (_) {
            // Try the next legacy phone field/format.
          }
        }
      }
    } catch (e) {
      debugPrint('PARTNER_PROFILE_BOOTSTRAP: $e');
    }
  }
}

class ClientSideOrderAssignmentService {
  static final FirebaseFirestore _db = FirebaseFirestore.instance;
  static StreamSubscription<User?>? _authSubscription;
  static StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
  _partnerSubscription;
  static StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
  _queueSubscription;
  static Timer? _queueTimer;
  static Timer? _heartbeatTimer;
  static String? _runningUid;
  static bool _assigning = false;
  static bool _started = false;

  static Future<void> initialize() async {
    if (_started) return;
    _started = true;
    _authSubscription = FirebaseAuth.instance.authStateChanges().listen((
      user,
    ) async {
      await _stop();
      if (user != null) {
        await PartnerProfileBootstrap.ensure();
        _start(user.uid);
      }
    });
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      await PartnerProfileBootstrap.ensure();
      _start(user.uid);
    }
  }

  /// Call this immediately after the partner switches Online.
  static Future<void> triggerNow() => _tryAssignOldestOrder();

  static void _start(String uid) {
    if (_runningUid == uid) return;
    _stopTimersAndPartnerListener();
    _runningUid = uid;
    final partnerRef = _db.collection('deliveryPartners').doc(uid);
    String? previousActiveOrderId;
    _partnerSubscription = partnerRef.snapshots().listen((snap) {
      final data = snap.data() ?? <String, dynamic>{};
      final activeOrderId = data['activeOrderId']?.toString().trim() ?? '';
      if (activeOrderId.isNotEmpty && activeOrderId != previousActiveOrderId) {
        previousActiveOrderId = activeOrderId;
        DeliveryOrderAlertService.start(activeOrderId);
      }
      if (activeOrderId.isEmpty) previousActiveOrderId = null;
      _tryAssignOldestOrder();
    }, onError: (_) {});

    // Real-time queue listener: a newly-created customer order wakes the
    // partner immediately. Admin app does not need to be running.
    _queueSubscription = _db
        .collection('deliveryQueue')
        .where('status', isEqualTo: 'pending')
        .snapshots()
        .listen((_) => _tryAssignOldestOrder(), onError: (_) {});

    _queueTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _tryAssignOldestOrder(),
    );
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _writeHeartbeat(),
    );
    _writeHeartbeat();
    _tryAssignOldestOrder();
  }

  static Future<void> _stop() async {
    _stopTimersAndPartnerListener();
    _runningUid = null;
  }

  static void _stopTimersAndPartnerListener() {
    _queueTimer?.cancel();
    _queueTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _partnerSubscription?.cancel();
    _partnerSubscription = null;
    _queueSubscription?.cancel();
    _queueSubscription = null;
  }

  static Future<void> _writeHeartbeat() async {
    final uid = _runningUid;
    if (uid == null) return;
    try {
      final ref = _db.collection('deliveryPartners').doc(uid);
      final snap = await ref.get();
      final data = snap.data() ?? <String, dynamic>{};
      if (data['online'] != true) return;
      await ref.set({
        'lastHeartbeatAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  static DateTime _time(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    if (value is String)
      return DateTime.tryParse(value) ?? DateTime.fromMillisecondsSinceEpoch(0);
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  static DateTime _orderQueueTime(Map<String, dynamic> data) {
    return _time(
      data['createdAt'] ??
          data['timestamp'] ??
          data['orderDate'] ??
          data['updatedAt'],
    );
  }

  static bool _isEligiblePartner(Map<String, dynamic> data) {
    if (data['active'] == false) return false;
    if (data['online'] != true) return false;
    if (data['availableForOrder'] == false) return false;
    final activeOrderId = data['activeOrderId']?.toString().trim() ?? '';
    if (activeOrderId.isNotEmpty) return false;
    final heartbeat = timestampFrom(data['lastHeartbeatAt']);
    if (heartbeat == null) return true;
    return DateTime.now().difference(heartbeat).inSeconds <= 45;
  }

  static bool _isActiveUnassigned(Map<String, dynamic> data) {
    final partnerId = data['deliveryPartnerId']?.toString().trim() ?? '';
    if (partnerId.isNotEmpty) return false;
    final status = (data['status'] ?? '').toString().trim().toLowerCase();
    return status != 'delivered' &&
        status != 'cancelled' &&
        status != 'cancelled by customer';
  }

  static Future<void> _tryAssignOldestOrder() async {
    if (_assigning) return;
    final uid = _runningUid ?? FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    _assigning = true;
    try {
      final partnerRef = _db.collection('deliveryPartners').doc(uid);
      final partnerSnap = await partnerRef.get();
      final partnerData = partnerSnap.data() ?? <String, dynamic>{};
      if (!_isEligiblePartner(partnerData)) return;

      // FIRST: claim the new deliveryQueue items. This path does not depend on Admin.
      final queueSnap = await _db
          .collection('deliveryQueue')
          .where('status', isEqualTo: 'pending')
          .limit(25)
          .get();
      final queues = [...queueSnap.docs];
      queues.sort(
        (a, b) =>
            _orderQueueTime(a.data()).compareTo(_orderQueueTime(b.data())),
      );
      for (final q in queues) {
        if (await _claimQueueItem(q.id, uid)) return;
      }

      // SECOND: repair legacy orders created before deliveryQueue was introduced.
      // These are the orders that previously stayed Pending until Admin opened.
      final legacy = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
      try {
        final emptySnap = await _db
            .collection('orders')
            .where('deliveryPartnerId', isEqualTo: '')
            .limit(50)
            .get();
        legacy.addAll(emptySnap.docs);
      } catch (_) {}
      try {
        final nullSnap = await _db
            .collection('orders')
            .where('deliveryPartnerId', isNull: true)
            .limit(50)
            .get();
        final existing = legacy.map((d) => d.id).toSet();
        legacy.addAll(nullSnap.docs.where((d) => !existing.contains(d.id)));
      } catch (_) {}

      legacy.removeWhere((d) => !_isActiveUnassigned(d.data()));
      legacy.sort(
        (a, b) =>
            _orderQueueTime(a.data()).compareTo(_orderQueueTime(b.data())),
      );
      if (legacy.isNotEmpty) {
        await _claimLegacyOrder(legacy.first, uid);
      }
    } catch (_) {
      // Retry on the next 2-second tick. No Admin app is required.
    } finally {
      _assigning = false;
    }
  }

  static Future<bool> _claimQueueItem(String queueId, String uid) async {
    final queueRef = _db.collection('deliveryQueue').doc(queueId);
    final orderRef = _db.collection('orders').doc(queueId);
    final partnerRef = _db.collection('deliveryPartners').doc(uid);

    try {
      final claimed = await _db.runTransaction<bool>((tx) async {
        // Read everything first, then perform all writes atomically. This is
        // important: the old two-step queue->order write could leave a queue
        // item permanently assigned if the second write failed.
        final q = await tx.get(queueRef);
        final p = await tx.get(partnerRef);
        if (!q.exists || !p.exists) return false;

        final qd = q.data() ?? <String, dynamic>{};
        final pd = p.data() ?? <String, dynamic>{};
        if (qd['status']?.toString().trim() != 'pending') return false;
        if ((qd['assignedPartnerId']?.toString().trim() ?? '').isNotEmpty) {
          return false;
        }
        if (!_isEligiblePartner(pd)) return false;

        final orderId = qd['orderId']?.toString().trim().isNotEmpty == true
            ? qd['orderId'].toString().trim()
            : queueId;
        final actualOrderRef = _db.collection('orders').doc(orderId);
        final o = await tx.get(actualOrderRef);
        if (!o.exists) return false;

        final od = o.data() ?? <String, dynamic>{};
        final currentPartner = od['deliveryPartnerId']?.toString().trim() ?? '';
        final status = od['status']?.toString().trim().toLowerCase() ?? '';
        if (currentPartner.isNotEmpty) return false;
        if (status == 'delivered' ||
            status == 'cancelled' ||
            status == 'cancelled by customer') {
          return false;
        }

        final name = pd['name']?.toString().trim().isNotEmpty == true
            ? pd['name'].toString().trim()
            : (pd['fullName']?.toString() ?? 'Delivery Partner');
        final phone =
            pd['phone']?.toString() ??
            pd['mobile']?.toString() ??
            pd['mobileNumber']?.toString() ??
            '';

        // Queue + order + partner change together. No Admin dependency.
        tx.update(actualOrderRef, {
          'deliveryPartnerId': uid,
          'deliveryPartnerName': name,
          'deliveryPartnerPhone': phone,
          'assignmentStatus': 'assigned',
          'assignedAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
        tx.update(queueRef, {
          'status': 'assigned',
          'assignedPartnerId': uid,
          'assignedAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
        tx.set(partnerRef, {
          'availableForOrder': false,
          'activeOrderId': orderId,
          'lastAssignedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        return true;
      });

      if (claimed) {
        _showAssignmentMessage(queueId);
      }
      return claimed;
    } catch (e) {
      debugPrint('QUEUE_ASSIGNMENT_ERROR: $e');
      return false;
    }
  }

  static Future<void> _claimLegacyOrder(
    QueryDocumentSnapshot<Map<String, dynamic>> order,
    String uid,
  ) async {
    final orderRef = _db.collection('orders').doc(order.id);
    final partnerRef = _db.collection('deliveryPartners').doc(uid);
    final assigned = await _db.runTransaction<bool>((tx) async {
      final o = await tx.get(orderRef);
      final p = await tx.get(partnerRef);
      if (!o.exists || !p.exists) return false;
      final od = o.data() ?? <String, dynamic>{};
      final pd = p.data() ?? <String, dynamic>{};
      if (!_isActiveUnassigned(od) || !_isEligiblePartner(pd)) return false;
      final name = pd['name']?.toString().trim().isNotEmpty == true
          ? pd['name'].toString()
          : (pd['fullName']?.toString() ?? 'Delivery Partner');
      final phone =
          pd['phone']?.toString() ??
          pd['mobile']?.toString() ??
          pd['mobileNumber']?.toString() ??
          '';
      tx.update(orderRef, {
        'deliveryPartnerId': uid,
        'deliveryPartnerName': name,
        'deliveryPartnerPhone': phone,
        'assignmentStatus': 'assigned',
        'assignedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      tx.set(partnerRef, {
        'availableForOrder': false,
        'activeOrderId': order.id,
        'lastAssignedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      return true;
    });
    if (assigned) _showAssignmentMessage(order.id);
  }

  static Future<void> _finishAssignment(
    String orderId,
    String uid, {
    DocumentReference<Map<String, dynamic>>? queueRef,
  }) async {
    final orderRef = _db.collection('orders').doc(orderId);
    final partnerRef = _db.collection('deliveryPartners').doc(uid);
    final orderSnap = await orderRef.get();
    final partnerSnap = await partnerRef.get();
    if (!orderSnap.exists || !partnerSnap.exists) return;
    final od = orderSnap.data() ?? <String, dynamic>{};
    final pd = partnerSnap.data() ?? <String, dynamic>{};
    if ((od['deliveryPartnerId']?.toString().trim() ?? '').isNotEmpty &&
        od['deliveryPartnerId']?.toString().trim() != uid)
      return;
    if (!_isEligiblePartner(pd)) return;
    final name = pd['name']?.toString().trim().isNotEmpty == true
        ? pd['name'].toString()
        : (pd['fullName']?.toString() ?? 'Delivery Partner');
    final phone =
        pd['phone']?.toString() ??
        pd['mobile']?.toString() ??
        pd['mobileNumber']?.toString() ??
        '';
    await orderRef.update({
      'deliveryPartnerId': uid,
      'deliveryPartnerName': name,
      'deliveryPartnerPhone': phone,
      'assignmentStatus': 'assigned',
      'assignedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    await partnerRef.set({
      'availableForOrder': false,
      'activeOrderId': orderId,
      'lastAssignedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    _showAssignmentMessage(orderId);
  }

  static void _showAssignmentMessage(String orderId) {
    PartnerLocalNotificationService.showOrderAlert(orderId);
    appScaffoldMessengerKey.currentState?.hideCurrentSnackBar();
    appScaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text('🚚 नया delivery order मिला: $orderId'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: 'ORDERS',
          onPressed: () {
            appNavigatorKey.currentState?.push(
              MaterialPageRoute(
                builder: (_) => const DeliveryNotificationOpenPage(),
              ),
            );
          },
        ),
      ),
    );
  }
}

class DeliveryNotificationOpenPage extends StatelessWidget {
  const DeliveryNotificationOpenPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'New Notification',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.notifications_active_rounded,
                size: 72,
                color: orange,
              ),
              const SizedBox(height: 16),
              const Text(
                'Notification received',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 8),
              const Text(
                'अपने Orders tab में जाकर assigned order देखें।',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 22),
              FilledButton.icon(
                onPressed: () {
                  Navigator.pushAndRemoveUntil(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const DeliveryDashboard(initialTab: 1),
                    ),
                    (route) => false,
                  );
                },
                icon: const Icon(Icons.receipt_long_rounded),
                label: const Text('OPEN MY ORDERS'),
                style: FilledButton.styleFrom(
                  backgroundColor: orange,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e) {
    // Firebase configuration errors are shown by the app instead of leaving
    // the process with an unhandled exception.
    runApp(FirebaseStartupErrorApp(error: e));
    return;
  }

  await PartnerProfileBootstrap.ensure();
  await PartnerLocalNotificationService.initialize();
  await DeliveryNotificationService.initialize();
  DeliveryAnnouncementService.initialize();
  await ClientSideOrderAssignmentService.initialize();

  runApp(const FlashCartDeliveryApp());
}

class FirebaseStartupErrorApp extends StatelessWidget {
  final Object error;

  const FirebaseStartupErrorApp({super.key, required this.error});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: appScaffoldMessengerKey,
      debugShowCheckedModeBanner: false,
      title: 'FlashCart Delivery',
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_off_rounded, size: 64, color: red),
                const SizedBox(height: 16),
                const Text(
                  'Firebase could not start',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 8),
                Text(
                  '$error',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.grey),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class FlashCartDeliveryApp extends StatelessWidget {
  const FlashCartDeliveryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'FlashCart Delivery',
      themeMode: ThemeMode.light,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: bg,
        fontFamily: 'Arial',
        colorScheme: ColorScheme.fromSeed(seedColor: orange),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: dark,
          elevation: 0,
          surfaceTintColor: Colors.white,
        ),
      ),

      // Keep the premium UI from overflowing when Android's text size
      // / accessibility scale is larger than normal.
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            textScaler: media.textScaler.clamp(
              minScaleFactor: 0.85,
              maxScaleFactor: 1.15,
            ),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },

      home: const DeliveryAuthGate(),
    );
  }
}

class DeliveryAuthGate extends StatelessWidget {
  const DeliveryAuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        debugPrint(
          'AUTH_STATE => user=${snapshot.data?.uid} hasData=${snapshot.hasData} connection=${snapshot.connectionState}',
        );
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SplashPage();
        }

        if (snapshot.hasError) {
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Authentication error\n${snapshot.error}',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          );
        }

        if (snapshot.hasData) return const DeliveryDashboard();
        return const DeliveryLoginPage();
      },
    );
  }
}

class SplashPage extends StatelessWidget {
  const SplashPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: orange,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircleAvatar(
              radius: 48,
              backgroundColor: Colors.white,
              child: Icon(
                Icons.delivery_dining_rounded,
                size: 58,
                color: orange,
              ),
            ),
            SizedBox(height: 18),
            Text(
              'FlashCart',
              style: TextStyle(
                color: Colors.white,
                fontSize: 34,
                fontWeight: FontWeight.w900,
              ),
            ),
            SizedBox(height: 4),
            Text(
              'DELIVERY PARTNER',
              style: TextStyle(
                color: Colors.white70,
                fontWeight: FontWeight.bold,
                letterSpacing: 2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class DeliveryLoginPage extends StatefulWidget {
  const DeliveryLoginPage({super.key});

  @override
  State<DeliveryLoginPage> createState() => _DeliveryLoginPageState();
}

class _DeliveryLoginPageState extends State<DeliveryLoginPage> {
  final phone = TextEditingController();
  final otp = TextEditingController();

  bool loading = false;
  bool codeSent = false;
  String? verificationId;
  int? resendToken;
  bool _authBusy = false;

  String normalizeIndianPhone(String value) {
    var valueClean = value.trim().replaceAll(RegExp(r'[\s-]'), '');

    if (valueClean.startsWith('+91')) {
      return valueClean;
    }

    if (valueClean.startsWith('91') && valueClean.length == 12) {
      return '+$valueClean';
    }

    if (valueClean.startsWith('0') && valueClean.length == 11) {
      valueClean = valueClean.substring(1);
    }

    if (RegExp(r'^\d{10}$').hasMatch(valueClean)) {
      return '+91$valueClean';
    }

    return valueClean;
  }

  Future<void> sendOtp() async {
    FocusScope.of(context).unfocus();

    final number = normalizeIndianPhone(phone.text);

    if (!RegExp(r'^\+91[6-9]\d{9}$').hasMatch(number)) {
      message('Valid 10 digit Indian mobile number डालें');
      return;
    }

    setState(() => loading = true);

    try {
      await FirebaseAuth.instance.verifyPhoneNumber(
        phoneNumber: number,
        timeout: const Duration(seconds: 60),
        forceResendingToken: resendToken,

        verificationCompleted: (PhoneAuthCredential credential) async {
          if (_authBusy) return;

          _authBusy = true;
          try {
            final result = await FirebaseAuth.instance.signInWithCredential(
              credential,
            );
            await authorizePartner(result.user);
          } on FirebaseAuthException catch (e) {
            if (mounted)
              message('Automatic OTP login failed: ${e.message ?? e.code}');
          } catch (e) {
            if (mounted) message('Login error: $e');
          } finally {
            _authBusy = false;
            if (mounted) setState(() => loading = false);
          }
        },

        verificationFailed: (FirebaseAuthException e) {
          if (!mounted) return;

          setState(() => loading = false);

          var text = 'OTP भेजा नहीं जा सका';

          switch (e.code) {
            case 'invalid-phone-number':
              text = 'Mobile number सही नहीं है';
              break;
            case 'too-many-requests':
              text = 'बहुत ज्यादा attempts हुए हैं। थोड़ी देर बाद कोशिश करें';
              break;
            case 'quota-exceeded':
              text = 'Firebase SMS quota समाप्त हो गया है';
              break;
            case 'operation-not-allowed':
              text = 'Firebase Console में Phone Authentication enable करें';
              break;
            default:
              if (e.message != null && e.message!.isNotEmpty) {
                text = e.message!;
              }
          }

          message(text);
        },

        codeSent: (String id, int? token) {
          if (!mounted) return;

          setState(() {
            verificationId = id;
            resendToken = token;
            codeSent = true;
            loading = false;
          });

          message('OTP आपके mobile number पर भेज दिया गया है');
        },

        codeAutoRetrievalTimeout: (String id) {
          verificationId = id;
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => loading = false);
      message('OTP error: $e');
    }
  }

  Future<void> verifyOtp() async {
    FocusScope.of(context).unfocus();

    final code = otp.text.trim();

    if (verificationId == null) {
      message('पहले OTP भेजें');
      return;
    }

    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      message('6 digit OTP डालें');
      return;
    }

    if (_authBusy) return;
    _authBusy = true;
    setState(() => loading = true);

    try {
      final credential = PhoneAuthProvider.credential(
        verificationId: verificationId!,
        smsCode: code,
      );

      final result = await FirebaseAuth.instance.signInWithCredential(
        credential,
      );

      await authorizePartner(result.user);
    } on FirebaseAuthException catch (e) {
      var text = 'OTP verification failed';

      switch (e.code) {
        case 'invalid-verification-code':
          text = 'OTP गलत है';
          break;
        case 'session-expired':
          text = 'OTP expire हो गया। नया OTP भेजें';
          break;
        case 'credential-already-in-use':
          text = 'यह mobile number किसी दूसरे account से जुड़ा है';
          break;
        default:
          if (e.message != null && e.message!.isNotEmpty) {
            text = e.message!;
          }
      }

      message(text);
    } catch (e) {
      message('Login error: $e');
    } finally {
      _authBusy = false;
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> authorizePartner(User? firebaseUser) async {
    if (firebaseUser == null) {
      throw FirebaseAuthException(
        code: 'missing-user',
        message: 'Firebase user account नहीं मिला',
      );
    }

    final uid = firebaseUser.uid;
    final partnerRef = FirebaseFirestore.instance
        .collection('deliveryPartners')
        .doc(uid);

    // Normal case: Admin has already created the partner document
    // using the Firebase Authentication UID.
    final direct = await partnerRef.get();
    debugPrint(
      'PARTNER_CHECK => uid=$uid exists=${direct.exists} data=${direct.data()}',
    );

    if (direct.exists) {
      await finishPartnerLogin(
        firebaseUser,
        partnerRef,
        direct.data() ?? <String, dynamic>{},
      );
      return;
    }

    // Compatibility case: older partner documents may have been created
    // with an auto-ID while storing the partner phone number.
    final phoneNumber = firebaseUser.phoneNumber;
    if (phoneNumber == null || phoneNumber.isEmpty) {
      debugPrint('AUTO_SIGNOUT => missing Firebase phone number');
      await FirebaseAuth.instance.signOut();
      message('Partner mobile number Firebase में नहीं मिला');
      return;
    }

    // If Admin approved the application before this phone ever signed in,
    // Firebase Phone Auth creates the Auth user on successful OTP verification.
    // Build the partner profile under that new Firebase UID from the approved
    // application so login works without the Admin app being open.
    try {
      final approved = await FirebaseFirestore.instance
          .collection('deliveryPartnerApplications')
          .where('phone', isEqualTo: phoneNumber)
          .where('status', isEqualTo: 'approved')
          .limit(1)
          .get();

      if (approved.docs.isNotEmpty) {
        final appDoc = approved.docs.first;
        final appData = Map<String, dynamic>.from(appDoc.data());

        // Preserve the branch assigned by Admin when the partner was approved.
        // Older profiles may use an auto-ID, so locate the approved profile by
        // phone before migrating it to the Firebase Auth UID document.
        Map<String, dynamic> existingPartnerData = <String, dynamic>{};
        String? existingPartnerDocId;
        final localPhone = phoneNumber.startsWith('+91')
            ? phoneNumber.substring(3)
            : phoneNumber;
        final phoneCandidates = <String>{
          phoneNumber,
          localPhone,
          '0$localPhone',
        };
        for (final field in ['phone', 'mobile', 'mobileNumber']) {
          for (final value in phoneCandidates) {
            final existing = await FirebaseFirestore.instance
                .collection('deliveryPartners')
                .where(field, isEqualTo: value)
                .limit(1)
                .get();
            final match = existing.docs.where((doc) => doc.id != uid).toList();
            if (match.isNotEmpty) {
              existingPartnerData = Map<String, dynamic>.from(
                match.first.data(),
              );
              existingPartnerDocId = match.first.id;
              break;
            }
          }
          if (existingPartnerData.isNotEmpty) break;
        }

        final migrated = <String, dynamic>{
          ...appData,
          ...existingPartnerData,
          'name':
              existingPartnerData['name'] ??
              appData['name'] ??
              appData['fullName'] ??
              'Delivery Partner',
          'phone': phoneNumber,
          'mobile':
              existingPartnerData['mobile'] ?? appData['mobile'] ?? localPhone,
          'mobileNumber':
              existingPartnerData['mobileNumber'] ??
              appData['mobileNumber'] ??
              localPhone,
          'vehicle': existingPartnerData['vehicle'] ?? appData['vehicle'] ?? '',
          'vehicleNumber':
              existingPartnerData['vehicleNumber'] ??
              appData['vehicleNumber'] ??
              '',
          'area': existingPartnerData['area'] ?? appData['area'] ?? '',
          // Never replace an already assigned branch with an empty value.
          if ((existingPartnerData['branchId'] ?? appData['branchId'] ?? '')
              .toString()
              .trim()
              .isNotEmpty)
            'branchId': existingPartnerData['branchId'] ?? appData['branchId'],
          if ((existingPartnerData['branchName'] ?? appData['branchName'] ?? '')
              .toString()
              .trim()
              .isNotEmpty)
            'branchName':
                existingPartnerData['branchName'] ?? appData['branchName'],
          'active': existingPartnerData['active'] ?? true,
          'online': false,
          'availableForOrder': false,
          'authUid': uid,
          'applicationId': appDoc.id,
          if (existingPartnerDocId != null && existingPartnerDocId != uid)
            'migratedFrom': existingPartnerDocId,
          'approvedAt':
              existingPartnerData['approvedAt'] ??
              appData['reviewedAt'] ??
              FieldValue.serverTimestamp(),
          'createdAt':
              existingPartnerData['createdAt'] ??
              appData['createdAt'] ??
              FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        };
        await partnerRef.set(migrated, SetOptions(merge: true));
        await finishPartnerLogin(firebaseUser, partnerRef, migrated);
        message(
          'Registration approved — Firebase account ready. Login successful ✅',
        );
        return;
      }
    } on FirebaseException catch (e) {
      debugPrint('APPROVED_APPLICATION_LOOKUP => ${e.code}: ${e.message}');
    }

    final localNumber = phoneNumber.startsWith('+91')
        ? phoneNumber.substring(3)
        : phoneNumber;

    final candidatePhones = <String>{
      phoneNumber,
      localNumber,
      '0$localNumber',
    }.toList();

    QuerySnapshot<Map<String, dynamic>>? found;

    for (final field in ['phone', 'mobile', 'mobileNumber']) {
      for (final value in candidatePhones) {
        try {
          final result = await FirebaseFirestore.instance
              .collection('deliveryPartners')
              .where(field, isEqualTo: value)
              .limit(1)
              .get();

          if (result.docs.isNotEmpty) {
            found = result;
            break;
          }
        } catch (_) {
          // Try the next supported field/format.
        }
      }

      if (found != null) break;
    }

    if (found == null || found.docs.isEmpty) {
      debugPrint('AUTO_SIGNOUT => partner profile not found');
      await FirebaseAuth.instance.signOut();
      message(
        'Delivery Partner profile नहीं मिला। Firebase में deliveryPartners का document ID उसी Firebase Auth UID से होना चाहिए.',
      );
      return;
    }

    final oldDoc = found.docs.first;
    final data = Map<String, dynamic>.from(oldDoc.data());

    if (data['active'] == false) {
      debugPrint('AUTO_SIGNOUT => partner inactive, data=$data');
      debugPrint('AUTO_SIGNOUT => finishPartnerLogin inactive, data=$data');
      await FirebaseAuth.instance.signOut();
      message('आपका Delivery Partner account inactive है');
      return;
    }

    // Copy the existing partner profile to the Firebase Auth UID.
    // This keeps the rest of this app's order/earning queries working,
    // because they use FirebaseAuth.currentUser.uid.
    data['phone'] = phoneNumber;
    data['authUid'] = uid;
    data['applicationId'] = data['applicationId'] ?? oldDoc.id;
    data['migratedFrom'] = oldDoc.id;
    data['updatedAt'] = FieldValue.serverTimestamp();

    await partnerRef.set(data, SetOptions(merge: true));

    if (!mounted) return;
    message('Login successful');
  }

  Future<void> finishPartnerLogin(
    User firebaseUser,
    DocumentReference<Map<String, dynamic>> partnerRef,
    Map<String, dynamic> data,
  ) async {
    if (data['active'] == false) {
      await FirebaseAuth.instance.signOut();
      message('आपका Delivery Partner account inactive है');
      return;
    }

    final existingPhone = data['phone']?.toString().trim() ?? '';
    if (existingPhone.isEmpty && firebaseUser.phoneNumber != null) {
      await partnerRef.set({
        'phone': firebaseUser.phoneNumber,
        'authUid': firebaseUser.uid,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }
  }

  void message(String text) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  void dispose() {
    phone.dispose();
    otp.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [orange, orange2, bg],
            stops: [0, .38, .38],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(22),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 460),
                padding: const EdgeInsets.all(26),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(30),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: .12),
                      blurRadius: 30,
                      offset: const Offset(0, 15),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    Container(
                      width: 84,
                      height: 84,
                      decoration: BoxDecoration(
                        color: orange,
                        borderRadius: BorderRadius.circular(25),
                      ),
                      child: const Icon(
                        Icons.delivery_dining_rounded,
                        color: Colors.white,
                        size: 50,
                      ),
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      'FlashCart',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w900,
                        decoration: TextDecoration.none,
                      ),
                    ),
                    const Text(
                      'DELIVERY PARTNER',
                      style: TextStyle(
                        color: orange,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.8,
                      ),
                    ),
                    const SizedBox(height: 30),

                    TextField(
                      controller: phone,
                      keyboardType: TextInputType.phone,
                      maxLength: 10,
                      enabled: !loading,
                      decoration: inputDecoration(
                        'Mobile Number (+91)',
                        Icons.phone_android_rounded,
                      ),
                    ),

                    if (codeSent) ...[
                      const SizedBox(height: 10),
                      TextField(
                        controller: otp,
                        keyboardType: TextInputType.number,
                        maxLength: 6,
                        enabled: !loading,
                        decoration: inputDecoration(
                          '6 Digit OTP',
                          Icons.lock_outline_rounded,
                        ),
                      ),
                    ],

                    const SizedBox(height: 14),

                    SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: ElevatedButton.icon(
                        onPressed: loading
                            ? null
                            : codeSent
                            ? verifyOtp
                            : sendOtp,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: orange,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        icon: loading
                            ? const SizedBox(
                                width: 21,
                                height: 21,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: Colors.white,
                                ),
                              )
                            : Icon(
                                codeSent
                                    ? Icons.verified_rounded
                                    : Icons.sms_rounded,
                              ),
                        label: Text(
                          codeSent ? 'Verify & Login' : 'Send OTP',
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),

                    if (codeSent) ...[
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: loading ? null : sendOtp,
                        child: const Text('Resend OTP'),
                      ),
                      TextButton(
                        onPressed: loading
                            ? null
                            : () {
                                setState(() {
                                  codeSent = false;
                                  verificationId = null;
                                  otp.clear();
                                });
                              },
                        child: const Text('Change Mobile Number'),
                      ),
                    ],

                    const SizedBox(height: 6),
                    const Text(
                      'Only registered Delivery Partners can login.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),

                    const SizedBox(height: 12),
                    const Row(
                      children: [
                        Expanded(child: Divider()),
                        Padding(
                          padding: EdgeInsets.symmetric(horizontal: 10),
                          child: Text(
                            'OR',
                            style: TextStyle(
                              color: Colors.grey,
                              fontWeight: FontWeight.w800,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        Expanded(child: Divider()),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: OutlinedButton.icon(
                        onPressed: loading
                            ? null
                            : () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        const DeliveryPartnerRegistrationPage(),
                                  ),
                                );
                              },
                        icon: const Icon(Icons.person_add_alt_1_rounded),
                        label: const Text(
                          'New Delivery Partner Registration',
                          style: TextStyle(fontWeight: FontWeight.w900),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: orange,
                          side: const BorderSide(color: orange, width: 1.5),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
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

class DeliveryPartnerRegistrationPage extends StatefulWidget {
  const DeliveryPartnerRegistrationPage({super.key});

  @override
  State<DeliveryPartnerRegistrationPage> createState() =>
      _DeliveryPartnerRegistrationPageState();
}

class _DeliveryPartnerRegistrationPageState
    extends State<DeliveryPartnerRegistrationPage> {
  final nameController = TextEditingController();
  final phoneController = TextEditingController();
  final vehicleNumberController = TextEditingController();
  final areaController = TextEditingController();
  final aadhaarNumberController = TextEditingController();

  String vehicle = 'Bike';
  String? selectedBranchId;
  String? selectedBranchName;
  List<Map<String, String>> availableBranches = <Map<String, String>>[];
  bool loadingBranches = true;
  String? aadhaarPhotoBase64;
  String? aadhaarPhotoName;
  bool submitting = false;

  final vehicles = const [
    'Bike',
    'Scooter',
    'Electric Scooter',
    'Cycle',
    'Other',
  ];

  @override
  void initState() {
    super.initState();
    _loadBranches();
  }

  Future<void> _loadBranches() async {
    if (mounted) setState(() => loadingBranches = true);
    try {
      final db = FirebaseFirestore.instance;
      final foundById = <String, Map<String, String>>{};

      // Registration is available before OTP login. Read ONLY the minimal,
      // public directory; do not query private branches/admins/managers here.
      final snap = await db.collection('publicStores').get();
      for (final doc in snap.docs) {
        final data = doc.data();
        if (data['active'] == false || data['isActive'] == false) continue;
        final name =
            (data['branchName'] ?? data['storeName'] ?? data['name'] ?? '')
                .toString()
                .trim();
        if (name.isEmpty) continue;
        final id = (data['branchId'] ?? doc.id).toString().trim();
        if (id.isEmpty) continue;
        foundById[id] = {'id': id, 'name': name};
      }

      final found = foundById.values.toList();
      found.sort(
        (a, b) => a['name']!.toLowerCase().compareTo(b['name']!.toLowerCase()),
      );
      if (!mounted) return;
      setState(() {
        availableBranches = found;
        loadingBranches = false;
        if (selectedBranchId != null &&
            !found.any((b) => b['id'] == selectedBranchId)) {
          selectedBranchId = null;
          selectedBranchName = null;
        }
        if (found.length == 1) {
          selectedBranchId = found.first['id'];
          selectedBranchName = found.first['name'];
        }
      });
      if (found.isEmpty) {
        _message(
          'अभी publicStores में कोई सक्रिय Store नहीं है। CEO/Admin के पुराने Stores को publicStores में एक बार जोड़ें।',
        );
      }
    } on FirebaseException catch (e) {
      if (!mounted) return;
      setState(() => loadingBranches = false);
      _message('Store list load नहीं हुई: [${e.code}] ${e.message ?? ''}');
    } catch (e) {
      if (!mounted) return;
      setState(() => loadingBranches = false);
      _message('Store list load नहीं हुई: $e');
    }
  }

  @override
  void dispose() {
    nameController.dispose();
    phoneController.dispose();
    vehicleNumberController.dispose();
    areaController.dispose();
    aadhaarNumberController.dispose();
    super.dispose();
  }

  String normalizePhone(String value) {
    final digits = value.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 10) return '+91$digits';
    if (digits.length == 12 && digits.startsWith('91')) return '+$digits';
    if (value.trim().startsWith('+91') && digits.length == 12) {
      return '+$digits';
    }
    return value.trim();
  }

  Future<void> pickAadhaarPhoto() async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 72,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      if (bytes.length > 900 * 1024) {
        _message('Aadhaar photo 900 KB से कम रखें');
        return;
      }
      if (!mounted) return;
      setState(() {
        aadhaarPhotoBase64 = base64Encode(bytes);
        aadhaarPhotoName = picked.name;
      });
    } catch (e) {
      _message('Aadhaar photo select नहीं हो पाई: $e');
    }
  }

  Future<void> submitApplication() async {
    FocusScope.of(context).unfocus();

    final name = nameController.text.trim();
    final phone = normalizePhone(phoneController.text);
    final vehicleNumber = vehicleNumberController.text.trim().toUpperCase();
    final area = areaController.text.trim();

    if (selectedBranchId == null || selectedBranchId!.trim().isEmpty) {
      _message('जिस Store में काम करना है, उसे चुनें');
      return;
    }

    if (name.length < 2) {
      _message('पूरा नाम दर्ज करें');
      return;
    }

    if (!RegExp(r'^\+91\d{10}$').hasMatch(phone)) {
      _message('10 digit valid mobile number दर्ज करें');
      return;
    }

    if (vehicleNumber.length < 3) {
      _message('Vehicle Number दर्ज करें');
      return;
    }

    if (area.length < 2) {
      _message('Delivery Area दर्ज करें');
      return;
    }

    final aadhaar = aadhaarNumberController.text.replaceAll(RegExp(r'\D'), '');
    if (!RegExp(r'^\d{12}$').hasMatch(aadhaar)) {
      _message('Valid 12 digit Aadhaar number दर्ज करें');
      return;
    }
    if (aadhaarPhotoBase64 == null || aadhaarPhotoBase64!.isEmpty) {
      _message('Aadhaar card की photo upload करें');
      return;
    }

    setState(() => submitting = true);

    try {
      final db = FirebaseFirestore.instance;

      // One application document per normalized mobile number. Use set() on the
      // deterministic document ID. Firestore rules must allow create but deny
      // applicant updates; then a repeated submission cannot create another ID.
      final phoneKey = phone.replaceAll(RegExp(r'\D'), '');
      final applicationRef = db
          .collection('deliveryPartnerApplications')
          .doc(phoneKey);
      await applicationRef.set({
        'name': name,
        'phone': phone,
        'mobile': phone.replaceFirst('+91', ''),
        'mobileNumber': phone.replaceFirst('+91', ''),
        'vehicle': vehicle,
        'vehicleNumber': vehicleNumber,
        'area': area,
        'branchId': selectedBranchId,
        'storeId': selectedBranchId,
        'branchName': selectedBranchName ?? '',
        'storeName': selectedBranchName ?? '',
        'aadhaarNumber': aadhaar,
        'aadhaarPhotoBase64': aadhaarPhotoBase64,
        'aadhaarPhotoName': aadhaarPhotoName ?? 'aadhaar.jpg',
        'identityKeyPhone': phoneKey,
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;

      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          icon: const Icon(Icons.check_circle_rounded, color: green, size: 54),
          title: const Text(
            'Registration Submitted',
            textAlign: TextAlign.center,
            style: TextStyle(fontWeight: FontWeight.w900),
          ),
          content: const Text(
            'आपकी Delivery Partner registration request Admin को भेज दी गई है। Approval के बाद इसी mobile number से OTP login करें।',
            textAlign: TextAlign.center,
          ),
          actions: [
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.pop(dialogContext),
                style: FilledButton.styleFrom(backgroundColor: orange),
                child: const Text('OK'),
              ),
            ),
          ],
        ),
      );

      if (mounted) Navigator.pop(context);
    } on FirebaseException catch (e) {
      if (mounted) {
        if (e.code == 'already-exists' || e.code == 'permission-denied') {
          _message(
            'इस मोबाइल नंबर से Registration पहले से मौजूद हो सकती है। नई ID न बनाएँ; Admin से मौजूदा ID/Store Transfer जाँच करवाएँ। अगर यह पहली Registration है, तो Firebase Console में सही project और deliveryPartnerApplications के create rule की पुष्टि करें।',
          );
        } else {
          _message(
            'Registration submit नहीं हुई: [${e.code}] ${e.message ?? ''}',
          );
        }
      }
    } catch (e) {
      if (mounted) _message('Registration submit नहीं हुई: $e');
    } finally {
      if (mounted) setState(() => submitting = false);
    }
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
        backgroundColor: red,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        title: const Text(
          'Delivery Partner Registration',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [orange, orange2],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(24),
              ),
              child: const Row(
                children: [
                  CircleAvatar(
                    radius: 29,
                    backgroundColor: Colors.white,
                    child: Icon(
                      Icons.delivery_dining_rounded,
                      color: orange,
                      size: 32,
                    ),
                  ),
                  SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Join FlashCart',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 21,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Registration → Admin Approval → OTP Login',
                          style: TextStyle(color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            _registrationField(
              nameController,
              'Full Name',
              Icons.person_outline_rounded,
            ),
            const SizedBox(height: 12),
            _registrationField(
              phoneController,
              'Mobile Number',
              Icons.phone_android_rounded,
              keyboard: TextInputType.phone,
              maxLength: 10,
            ),
            const SizedBox(height: 12),
            if (loadingBranches)
              const LinearProgressIndicator()
            else if (availableBranches.isEmpty)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'अभी कोई Store उपलब्ध नहीं है। CEO/Admin से Store Registration करवाएँ।',
                    ),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: loadingBranches || submitting
                          ? null
                          : () {
                              setState(() => loadingBranches = true);
                              _loadBranches();
                            },
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('Store List Refresh करें'),
                    ),
                  ],
                ),
              )
            else
              DropdownButtonFormField<String>(
                value: selectedBranchId,
                isExpanded: true,
                decoration: inputDecoration(
                  'Select Store / Branch',
                  Icons.storefront_rounded,
                ),
                items: availableBranches
                    .map(
                      (branch) => DropdownMenuItem<String>(
                        value: branch['id'],
                        child: Text(
                          '${branch['name']} (${branch['id']})',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: submitting
                    ? null
                    : (id) {
                        Map<String, String>? branch;
                        for (final item in availableBranches) {
                          if (item['id'] == id) {
                            branch = item;
                            break;
                          }
                        }
                        setState(() {
                          selectedBranchId = id;
                          selectedBranchName = branch?['name'];
                        });
                      },
              ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: vehicle,
              decoration: inputDecoration(
                'Vehicle Type',
                Icons.two_wheeler_rounded,
              ),
              items: vehicles
                  .map(
                    (item) => DropdownMenuItem<String>(
                      value: item,
                      child: Text(item),
                    ),
                  )
                  .toList(),
              onChanged: submitting
                  ? null
                  : (value) {
                      if (value != null) setState(() => vehicle = value);
                    },
            ),
            const SizedBox(height: 12),
            _registrationField(
              vehicleNumberController,
              'Vehicle Number',
              Icons.confirmation_number_outlined,
              textCapitalization: TextCapitalization.characters,
            ),
            const SizedBox(height: 12),
            _registrationField(
              areaController,
              'Delivery Area',
              Icons.location_city_outlined,
            ),
            const SizedBox(height: 12),
            _registrationField(
              aadhaarNumberController,
              'Aadhaar Number',
              Icons.badge_outlined,
              keyboard: TextInputType.number,
              maxLength: 12,
            ),
            const SizedBox(height: 12),
            InkWell(
              onTap: submitting ? null : pickAadhaarPhoto,
              borderRadius: BorderRadius.circular(16),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFE5E7EB)),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        color: orange.withValues(alpha: .10),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: aadhaarPhotoBase64 == null
                          ? const Icon(
                              Icons.upload_file_rounded,
                              color: orange,
                              size: 28,
                            )
                          : ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: Image.memory(
                                base64Decode(aadhaarPhotoBase64!),
                                fit: BoxFit.cover,
                              ),
                            ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            aadhaarPhotoBase64 == null
                                ? 'Upload Aadhaar Photo'
                                : 'Aadhaar Photo Selected',
                            style: const TextStyle(fontWeight: FontWeight.w900),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            aadhaarPhotoName ??
                                'Gallery से Aadhaar card की साफ photo चुनें',
                            style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right_rounded),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF8F2),
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: const Color(0xFFFFD7C5)),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline_rounded, color: orange),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Registration submit करने के बाद Admin आपकी details verify करेगा। Approval के बाद ही आप online होकर orders receive कर पाएँगे।',
                      style: TextStyle(height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              height: 55,
              child: FilledButton.icon(
                onPressed:
                    submitting || loadingBranches || availableBranches.isEmpty
                    ? null
                    : submitApplication,
                style: FilledButton.styleFrom(
                  backgroundColor: orange,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                icon: submitting
                    ? const SizedBox(
                        width: 21,
                        height: 21,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.send_rounded),
                label: Text(
                  submitting ? 'Submitting...' : 'Submit Registration',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _registrationField(
    TextEditingController controller,
    String label,
    IconData icon, {
    TextInputType keyboard = TextInputType.text,
    int? maxLength,
    TextCapitalization textCapitalization = TextCapitalization.words,
  }) {
    return TextField(
      controller: controller,
      enabled: !submitting,
      keyboardType: keyboard,
      maxLength: maxLength,
      textCapitalization: textCapitalization,
      decoration: inputDecoration(label, icon),
    );
  }
}

class DeliveryDashboard extends StatefulWidget {
  final int initialTab;

  const DeliveryDashboard({super.key, this.initialTab = 0});

  @override
  State<DeliveryDashboard> createState() => _DeliveryDashboardState();
}

class _DeliveryDashboardState extends State<DeliveryDashboard> {
  late int tab;

  @override
  void initState() {
    super.initState();
    tab = widget.initialTab.clamp(0, 3).toInt();
  }

  final pages = const [
    PremiumHomePage(),
    AssignedOrdersPage(),
    EarningsPage(),
    PartnerProfilePage(),
    PartnerBankDetailsPage(),
  ];

  Future<void> logout() async {
    final shouldLogout = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Logout?'),
        content: const Text(
          'क्या आप FlashCart Delivery से logout करना चाहते हैं?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: red),
            child: const Text('Logout'),
          ),
        ],
      ),
    );

    if (shouldLogout == true) {
      await FirebaseAuth.instance.signOut();
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('deliveryPartners')
          .doc(FirebaseAuth.instance.currentUser!.uid)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(
            appBar: AppBar(title: const Text('FlashCart Delivery')),
            body: _StreamErrorView(
              message: 'Partner profile load नहीं हुआ',
              error: snapshot.error,
            ),
          );
        }

        final partner = snapshot.data?.data() ?? {};
        final name = partner['name']?.toString().trim();
        final partnerName = name == null || name.isEmpty
            ? 'Delivery Partner'
            : name;

        return Scaffold(
          appBar: AppBar(
            titleSpacing: 18,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Hi, $partnerName 👋',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const Text(
                  'FlashCart Delivery',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: 'Notifications',
                onPressed: () => showNotifications(context),
                icon: const Icon(Icons.notifications_none_rounded),
              ),
              PopupMenuButton<String>(
                tooltip: 'Menu',
                icon: const Icon(Icons.more_vert_rounded),
                onSelected: (value) {
                  switch (value) {
                    case 'profile':
                      setState(() => tab = 3);
                      break;
                    case 'orders':
                      setState(() => tab = 1);
                      break;
                    case 'earnings':
                      setState(() => tab = 2);
                      break;
                    case 'notifications':
                      showNotifications(context);
                      break;
                    case 'support':
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const PartnerSupportPage(),
                        ),
                      );
                      break;
                    case 'help':
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const DeliveryHelpPage(),
                        ),
                      );
                      break;
                    case 'training':
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const DeliveryTrainingPage(),
                        ),
                      );
                      break;
                    case 'assets':
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const DeliveryAssetsPage(),
                        ),
                      );
                      break;
                    case 'emergency':
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const PartnerEmergencyPage(),
                        ),
                      );
                      break;
                    case 'settings':
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const PartnerSettingsPage(),
                        ),
                      );
                      break;
                    case 'logout':
                      logout();
                      break;
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem<String>(
                    value: 'profile',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.person_outline_rounded),
                      title: Text('My Profile'),
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'orders',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.receipt_long_rounded),
                      title: Text('My Orders'),
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'earnings',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.account_balance_wallet_rounded),
                      title: Text('My Earnings'),
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'notifications',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.notifications_none_rounded),
                      title: Text('Notifications'),
                    ),
                  ),
                  PopupMenuDivider(),
                  PopupMenuItem<String>(
                    value: 'support',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.support_agent_rounded),
                      title: Text('Customer Support / Complaint'),
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'help',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.help_outline_rounded),
                      title: Text('Help & Delivery Guide'),
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'training',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.play_circle_outline_rounded),
                      title: Text('Training Videos'),
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'assets',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.inventory_2_rounded),
                      title: Text('Assets / Store Items'),
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'emergency',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.emergency_rounded, color: red),
                      title: Text('Emergency / Help'),
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'settings',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.settings_outlined),
                      title: Text('Settings'),
                    ),
                  ),
                  PopupMenuDivider(),
                  PopupMenuItem<String>(
                    value: 'logout',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.logout_rounded, color: red),
                      title: Text('Logout', style: TextStyle(color: red)),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 5),
            ],
          ),
          body: IndexedStack(index: tab, children: pages),
          bottomNavigationBar: NavigationBar(
            height: 74,
            selectedIndex: tab,
            backgroundColor: Colors.white,
            indicatorColor: const Color(0xFFFFE1D5),
            onDestinationSelected: (i) => setState(() => tab = i),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home_rounded, color: orange),
                label: 'Home',
              ),
              NavigationDestination(
                icon: Icon(Icons.receipt_long_outlined),
                selectedIcon: Icon(Icons.receipt_long_rounded, color: orange),
                label: 'Orders',
              ),
              NavigationDestination(
                icon: Icon(Icons.account_balance_wallet_outlined),
                selectedIcon: Icon(
                  Icons.account_balance_wallet_rounded,
                  color: orange,
                ),
                label: 'Earnings',
              ),
              NavigationDestination(
                icon: Icon(Icons.person_outline_rounded),
                selectedIcon: Icon(Icons.person_rounded, color: orange),
                label: 'Profile',
              ),
              NavigationDestination(
                icon: Icon(Icons.account_balance_outlined),
                selectedIcon: Icon(
                  Icons.account_balance_rounded,
                  color: orange,
                ),
                label: 'Bank',
              ),
            ],
          ),
        );
      },
    );
  }

  void showNotifications(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .68,
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance
                .collection('orders')
                .where('deliveryPartnerId', isEqualTo: uid)
                .limit(20)
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Notifications load नहीं हुए.\n${snapshot.error}',
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              }

              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(
                  child: CircularProgressIndicator(color: orange),
                );
              }

              final docs = [...(snapshot.data?.docs ?? [])];
              docs.sort((a, b) {
                final at =
                    timestampFrom(
                      a.data()['updatedAt'] ?? a.data()['orderDate'],
                    )?.millisecondsSinceEpoch ??
                    0;
                final bt =
                    timestampFrom(
                      b.data()['updatedAt'] ?? b.data()['orderDate'],
                    )?.millisecondsSinceEpoch ??
                    0;
                return bt.compareTo(at);
              });

              if (docs.isEmpty) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircleAvatar(
                          radius: 30,
                          backgroundColor: Color(0xFFFFEDE6),
                          child: Icon(
                            Icons.notifications_none_rounded,
                            color: orange,
                            size: 32,
                          ),
                        ),
                        SizedBox(height: 12),
                        Text(
                          'No notifications',
                          style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        SizedBox(height: 5),
                        Text(
                          'New assigned orders and order updates will appear here.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                );
              }

              return ListView(
                padding: const EdgeInsets.fromLTRB(20, 5, 20, 30),
                children: [
                  const Text(
                    'Notifications',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Your latest assigned order activity',
                    style: TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 14),
                  ...docs.map((doc) {
                    final data = doc.data();
                    final status = data['status']?.toString() ?? 'Pending';
                    final customer =
                        data['customerName']?.toString() ??
                        data['name']?.toString() ??
                        'Customer';
                    final earning = moneyFrom(
                      data['deliveryEarning'] ??
                          data['partnerEarning'] ??
                          data['earning'] ??
                          calculateDeliveryEarning(data),
                    );
                    final time = timestampFrom(
                      data['updatedAt'] ?? data['orderDate'],
                    );

                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(17),
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.all(12),
                        leading: CircleAvatar(
                          backgroundColor: const Color(0xFFFFEDE6),
                          child: Icon(
                            status == 'Delivered'
                                ? Icons.check_circle_outline_rounded
                                : Icons.local_shipping_outlined,
                            color: status == 'Delivered' ? green : orange,
                          ),
                        ),
                        title: Text(
                          'Order #${doc.id}',
                          style: const TextStyle(fontWeight: FontWeight.w900),
                        ),
                        subtitle: Text(
                          '$customer • $status'
                          '${earning > 0 ? ' • ₹${earning.toStringAsFixed(0)}' : ''}'
                          '${time != null ? '\n${time.toLocal().toString().substring(0, 16)}' : ''}',
                        ),
                      ),
                    );
                  }),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _StreamErrorView extends StatelessWidget {
  final String message;
  final Object? error;

  const _StreamErrorView({required this.message, this.error});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 52, color: red),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
            ),
            if (error != null) ...[
              const SizedBox(height: 6),
              Text(
                '$error',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class PremiumHomePage extends StatefulWidget {
  const PremiumHomePage({super.key});

  @override
  State<PremiumHomePage> createState() => _PremiumHomePageState();
}

class _PremiumHomePageState extends State<PremiumHomePage>
    with AutomaticKeepAliveClientMixin {
  User get user => FirebaseAuth.instance.currentUser!;

  late final Stream<DocumentSnapshot<Map<String, dynamic>>> _partnerStream;
  late final Stream<QuerySnapshot<Map<String, dynamic>>> _ordersStream;

  @override
  void initState() {
    super.initState();

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      _partnerStream = const Stream.empty();
      _ordersStream = const Stream.empty();
      return;
    }

    // Keep Firestore stream instances stable. Recreating snapshots() inside
    // build() can cause unsubscribe/resubscribe cycles and visible flicker.
    _partnerStream = FirebaseFirestore.instance
        .collection('deliveryPartners')
        .doc(uid)
        .snapshots();

    _ordersStream = FirebaseFirestore.instance
        .collection('orders')
        .where('deliveryPartnerId', isEqualTo: uid)
        .snapshots();
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _partnerStream,
      builder: (context, partnerSnapshot) {
        final partner = partnerSnapshot.data?.data() ?? <String, dynamic>{};
        final isOnline = partner['online'] == true;

        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: _ordersStream,
          builder: (context, orderSnapshot) {
            if (orderSnapshot.hasError) {
              return _StreamErrorView(
                message: 'Orders load नहीं हो सके',
                error: orderSnapshot.error,
              );
            }

            final docs = [...(orderSnapshot.data?.docs ?? const [])];

            docs.sort((a, b) {
              final at =
                  timestampFrom(a.data()['orderDate'])
                      ?.millisecondsSinceEpoch ??
                  0;
              final bt =
                  timestampFrom(b.data()['orderDate'])
                      ?.millisecondsSinceEpoch ??
                  0;
              return bt.compareTo(at);
            });

            final active = docs.where((d) {
              final s = d.data()['status']?.toString() ?? '';
              return s != 'Delivered' && s != 'Cancelled';
            }).toList();

            final deliveredToday = docs.where((d) {
              final data = d.data();
              return data['status']?.toString() == 'Delivered' &&
                  sameDay(timestampFrom(data['deliveredAt']), DateTime.now());
            }).toList();

            final todayEarnings = deliveredToday.fold<double>(
              0,
              (total, d) =>
                  total +
                  moneyFrom(
                    d.data()['deliveryEarning'] ??
                        d.data()['partnerEarning'] ??
                        d.data()['earning'] ??
                        calculateDeliveryEarning(d.data()),
                  ),
            );

            // Keep the last rendered UI stable while Firestore reconnects.
            if (orderSnapshot.connectionState == ConnectionState.waiting &&
                !orderSnapshot.hasData) {
              return const Center(
                child: CircularProgressIndicator(color: orange),
              );
            }

            return RefreshIndicator(
              color: orange,
              onRefresh: () async {
                await Future<void>.delayed(const Duration(milliseconds: 250));
              },
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                children: [
                  // Show the store/branch assigned to this logged-in partner.
                  StoreBranchCard(partner: partner),
                  const SizedBox(height: 12),
                  OnlineCard(isOnline: isOnline),
                  const SizedBox(height: 14),
                  EarningsHero(
                    earnings: todayEarnings,
                    orders: deliveredToday.length,
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Active Order',
                          style: TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      if (active.isNotEmpty)
                        Text(
                          '${active.length} pending',
                          style: const TextStyle(
                            color: orange,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (active.isEmpty)
                    const EmptyActiveCard()
                  else
                    DeliveryOrderCard(
                      orderId: active.first.id,
                      data: active.first.data(),
                      compact: true,
                    ),
                  const SizedBox(height: 20),
                  const Text(
                    'Quick Actions',
                    style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 10),
                  const QuickActions(),
                  const SizedBox(height: 20),
                  const ReferralCard(),
                  const SizedBox(height: 14),
                  const WeeklyPayoutCard(),
                  const SizedBox(height: 14),
                  const VehicleCard(),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class StoreBranchCard extends StatelessWidget {
  final Map<String, dynamic> partner;

  const StoreBranchCard({super.key, required this.partner});

  @override
  Widget build(BuildContext context) {
    final storeName =
        (partner['branchName'] ??
                partner['storeName'] ??
                partner['branch_name'] ??
                '')
            .toString()
            .trim();
    final branchId = (partner['branchId'] ?? partner['storeId'] ?? '')
        .toString()
        .trim();
    final area = (partner['area'] ?? partner['branchArea'] ?? '')
        .toString()
        .trim();
    final hasAssignment = storeName.isNotEmpty || branchId.isNotEmpty;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: orange.withValues(alpha: .20)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .035),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: const Color(0xFFFFEEE8),
              borderRadius: BorderRadius.circular(15),
            ),
            child: const Icon(
              Icons.storefront_rounded,
              color: orange,
              size: 27,
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'YOUR ASSIGNED STORE',
                  style: TextStyle(
                    color: Colors.grey,
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.0,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  hasAssignment
                      ? (storeName.isNotEmpty ? storeName : 'Assigned Store')
                      : 'Store assignment not found',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: dark,
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                if (branchId.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    'Branch ID: $branchId',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.black54,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                if (area.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      const Icon(
                        Icons.location_on_outlined,
                        size: 14,
                        color: orange,
                      ),
                      const SizedBox(width: 3),
                      Expanded(
                        child: Text(
                          area,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.black54,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                if (!hasAssignment) ...[
                  const SizedBox(height: 4),
                  const Text(
                    'Please contact Admin to confirm your branch.',
                    style: TextStyle(color: red, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
          const Icon(Icons.verified_rounded, color: green, size: 22),
        ],
      ),
    );
  }
}

class OnlineCard extends StatelessWidget {
  final bool isOnline;

  const OnlineCard({super.key, required this.isOnline});

  Future<void> toggle(BuildContext context) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    try {
      if (isOnline) {
        await FirebaseFirestore.instance
            .collection('deliveryPartners')
            .doc(uid)
            .update({
              'online': false,
              'availableForOrder': false,
              'lastOfflineAt': FieldValue.serverTimestamp(),
            });
      } else {
        final ref = FirebaseFirestore.instance
            .collection('deliveryPartners')
            .doc(uid);
        final snap = await ref.get();
        final data = snap.data() ?? <String, dynamic>{};
        await ref.update({
          'online': true,
          'availableForOrder': true,
          'onlineSince': FieldValue.serverTimestamp(),
          'lastOnlineAt': FieldValue.serverTimestamp(),
        });
        await ClientSideOrderAssignmentService.triggerNow();
      }
    } catch (e) {
      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Online status update नहीं हुआ: $e'),
          backgroundColor: red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(17),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [orange, orange2],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: orange.withValues(alpha: .22),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: .18),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(
              Icons.bolt_rounded,
              color: Colors.white,
              size: 30,
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isOnline ? 'You are Online' : 'You are Offline',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                Text(
                  isOnline
                      ? 'Ready to receive new orders'
                      : 'Go online to receive orders',
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ),
          ),
          Switch(
            value: isOnline,
            onChanged: (_) => toggle(context),
            thumbColor: WidgetStatePropertyAll(Colors.white),
            activeTrackColor: green,
          ),
        ],
      ),
    );
  }
}

class EarningsHero extends StatelessWidget {
  final double earnings;
  final int orders;

  const EarningsHero({super.key, required this.earnings, required this.orders});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(21),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [dark, Color(0xFF303030)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(26),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.currency_rupee_rounded, color: yellow),
              SizedBox(width: 6),
              Text(
                "TODAY'S EARNINGS",
                style: TextStyle(
                  color: Colors.white70,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '₹${formatMoney(earnings)}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 34,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              statMini('Orders', '$orders'),
              const SizedBox(width: 8),
              statMini('Tips', 'See earnings'),
              const SizedBox(width: 8),
              statMini('Status', 'Active'),
            ],
          ),
        ],
      ),
    );
  }

  Widget statMini(String title, String value) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(color: Colors.white54)),
            const SizedBox(height: 3),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class EmptyActiveCard extends StatelessWidget {
  const EmptyActiveCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(25),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
      ),
      child: const Column(
        children: [
          CircleAvatar(
            radius: 32,
            backgroundColor: Color(0xFFFFEFE9),
            child: Icon(Icons.delivery_dining_rounded, color: orange, size: 34),
          ),
          SizedBox(height: 12),
          Text(
            'No active orders',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
          ),
          SizedBox(height: 5),
          Text(
            'Admin से order assign होने पर यहाँ दिखेगा',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }
}

class QuickActions extends StatelessWidget {
  const QuickActions({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: actionCard(
            Icons.card_giftcard_rounded,
            'Refer',
            '₹14,000',
            purple,
            () => showReferral(context),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: actionCard(
            Icons.account_balance_wallet_rounded,
            'Payouts',
            'Weekly',
            green,
            () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const EarningsPage())),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: actionCard(
            Icons.two_wheeler_rounded,
            'Vehicle',
            'Rent',
            blue,
            () => showVehicle(context),
          ),
        ),
      ],
    );
  }

  Widget actionCard(
    IconData icon,
    String title,
    String subtitle,
    Color iconColor,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(19),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 14, 10, 13),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(19),
        ),
        child: Column(
          children: [
            CircleAvatar(
              backgroundColor: iconColor.withValues(alpha: .11),
              child: Icon(icon, color: iconColor),
            ),
            const SizedBox(height: 8),
            Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}

class ReferralCard extends StatelessWidget {
  const ReferralCard({super.key});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => showReferral(context),
      borderRadius: BorderRadius.circular(25),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFFFFD43B), Color(0xFFFFB300)],
          ),
          borderRadius: BorderRadius.circular(25),
        ),
        child: Row(
          children: [
            Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .8),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.card_giftcard_rounded,
                color: dark,
                size: 30,
              ),
            ),
            const SizedBox(width: 14),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'REFER & EARN',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1,
                    ),
                  ),
                  SizedBox(height: 3),
                  Text(
                    'Earn up to ₹14,000',
                    style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900),
                  ),
                  Text(
                    'Invite your friends to FlashCart',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios_rounded, size: 18),
          ],
        ),
      ),
    );
  }
}

class WeeklyPayoutCard extends StatelessWidget {
  const WeeklyPayoutCard({super.key});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const EarningsPage()));
      },
      borderRadius: BorderRadius.circular(23),
      child: Container(
        constraints: const BoxConstraints(minHeight: 104),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(23),
          border: Border.all(color: const Color(0xFFE9EAF0)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const CircleAvatar(
              radius: 22,
              backgroundColor: Color(0xFFEAF8EE),
              child: Icon(Icons.payments_rounded, color: green),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'WEEKLY PAYOUTS',
                      maxLines: 1,
                      style: TextStyle(
                        color: green,
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                        letterSpacing: .6,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Get payouts every Monday',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    'Full earning visibility',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.grey, fontSize: 11),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.arrow_forward_ios_rounded, size: 16),
          ],
        ),
      ),
    );
  }
}

class VehicleCard extends StatelessWidget {
  const VehicleCard({super.key});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => showVehicle(context),
      borderRadius: BorderRadius.circular(23),
      child: Container(
        padding: const EdgeInsets.all(19),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFFE9F2FF), Colors.white],
          ),
          borderRadius: BorderRadius.circular(23),
        ),
        child: const Row(
          children: [
            CircleAvatar(
              radius: 27,
              backgroundColor: Color(0xFFDDEAFF),
              child: Icon(Icons.electric_scooter_rounded, color: blue),
            ),
            SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'NO VEHICLE? NO PROBLEM',
                    style: TextStyle(
                      color: blue,
                      fontWeight: FontWeight.w900,
                      letterSpacing: .6,
                    ),
                  ),
                  SizedBox(height: 3),
                  Text(
                    'Rent a vehicle and start working',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  Text(
                    'Affordable daily rental options',
                    style: TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            ),
            Icon(Icons.arrow_forward_ios_rounded, size: 17),
          ],
        ),
      ),
    );
  }
}

Widget _partnerOrderItems(List items) {
  if (items.isEmpty) return const SizedBox.shrink();
  return Container(
    width: double.infinity,
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: const Color(0xFFF8FAFC),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xFFE5E7EB)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Pickup Products',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
        ),
        const SizedBox(height: 6),
        ...items.whereType<Map>().map((item) {
          final name =
              (item['name'] ??
                      item['productName'] ??
                      item['title'] ??
                      item['product_name'] ??
                      'Product')
                  .toString();
          final image =
              (item['imageUrl'] ??
                      item['image'] ??
                      item['photoUrl'] ??
                      item['productImage'] ??
                      item['thumbnail'] ??
                      '')
                  .toString();
          final qty = item['quantity'] ?? item['qty'] ?? item['count'] ?? 1;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 54,
                    height: 54,
                    child: image.startsWith('http')
                        ? Image.network(
                            image,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) =>
                                const Icon(Icons.shopping_basket_outlined),
                          )
                        : const Icon(Icons.shopping_basket_outlined),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '$name\nQty: $qty',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    ),
  );
}

class AssignedOrdersPage extends StatelessWidget {
  const AssignedOrdersPage({super.key});

  User get user => FirebaseAuth.instance.currentUser!;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('orders')
          .where('deliveryPartnerId', isEqualTo: user.uid)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(color: orange));
        }

        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                'Orders load नहीं हो सके.\n${snapshot.error}',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        final docs = [...(snapshot.data?.docs ?? [])];
        docs.sort((a, b) {
          final at =
              timestampFrom(a.data()['orderDate'])?.millisecondsSinceEpoch ?? 0;
          final bt =
              timestampFrom(b.data()['orderDate'])?.millisecondsSinceEpoch ?? 0;
          return bt.compareTo(at);
        });

        final active = docs.where((d) {
          final s = d.data()['status']?.toString() ?? '';
          return s != 'Delivered' && s != 'Cancelled';
        }).toList();

        if (active.isEmpty) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: const [SizedBox(height: 90), EmptyActiveCard()],
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: active.length,
          itemBuilder: (context, index) {
            final doc = active[index];
            return DeliveryOrderCard(orderId: doc.id, data: doc.data());
          },
        );
      },
    );
  }
}

class DeliveryOrderCard extends StatelessWidget {
  final String orderId;
  final Map<String, dynamic> data;
  final bool compact;

  const DeliveryOrderCard({
    super.key,
    required this.orderId,
    required this.data,
    this.compact = false,
  });

  String get status =>
      (data['cancelled'] == true ||
          data['cancelRequested'] == true ||
          data['cancellationRequested'] == true)
      ? 'Cancelled'
      : (data['status']?.toString() ?? 'Order Placed');

  String get customerName {
    final value = data['customerName']?.toString().trim();
    return value == null || value.isEmpty ? 'Customer' : value;
  }

  String get customerPhone {
    final p = data['userPhone'] ?? data['phone'] ?? data['customerPhone'] ?? '';
    return p.toString();
  }

  String get address {
    final a = data['deliveryAddress']?.toString().trim();
    return a == null || a.isEmpty ? 'Address not available' : a;
  }

  double? get deliveryLatitude {
    final value = data['deliveryLatitude'];
    return value is num ? value.toDouble() : null;
  }

  double? get deliveryLongitude {
    final value = data['deliveryLongitude'];
    return value is num ? value.toDouble() : null;
  }

  bool get hasExactLocation =>
      deliveryLatitude != null && deliveryLongitude != null;

  List get items {
    final raw =
        data['items'] ??
        data['orderItems'] ??
        data['cartItems'] ??
        data['products'];
    return raw is List ? List.from(raw) : <dynamic>[];
  }

  String normalizedStatus(String value) {
    final normalized = value.trim().toLowerCase();

    switch (normalized) {
      case 'order placed':
      case 'pending':
        return 'Pending';
      case 'confirmed':
      case 'order confirmed':
        return 'Confirmed';
      case 'preparing':
        return 'Preparing';
      case 'out for delivery':
        return 'Out for Delivery';
      case 'delivered':
        return 'Delivered';
      case 'cancelled':
      case 'canceled':
      case 'cancelled by customer':
      case 'canceled by customer':
        return 'Cancelled';
      default:
        return value.trim();
    }
  }

  String nextStatus() {
    switch (normalizedStatus(status)) {
      case 'Pending':
        return 'Confirmed';
      case 'Confirmed':
        return 'Preparing';
      case 'Preparing':
        return 'Out for Delivery';
      case 'Out for Delivery':
        return 'Delivered';
      default:
        return status;
    }
  }

  Future<void> updateStatus(BuildContext context) async {
    final next = nextStatus();
    if (next == status) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Login session समाप्त हो गया। फिर से login करें।'),
            backgroundColor: red,
          ),
        );
      }
      return;
    }

    try {
      final db = FirebaseFirestore.instance;
      final orderRef = db.collection('orders').doc(orderId);
      final partnerRef = db.collection('deliveryPartners').doc(user.uid);

      // Read the latest order before changing the status. This prevents an
      // old/stale order card from writing the wrong next status.
      final latest = await orderRef.get();
      if (!latest.exists) {
        throw FirebaseException(
          plugin: 'cloud_firestore',
          code: 'not-found',
          message: 'Order नहीं मिला: $orderId',
        );
      }

      final latestData = latest.data() ?? <String, dynamic>{};
      final assignedPartnerId =
          latestData['deliveryPartnerId']?.toString().trim() ?? '';

      if (assignedPartnerId != user.uid) {
        throw FirebaseException(
          plugin: 'cloud_firestore',
          code: 'permission-denied',
          message:
              'यह order इस Delivery Partner को assigned नहीं है।\nOrder Partner: $assignedPartnerId\nCurrent Partner: ${user.uid}',
        );
      }

      final rawCurrentStatus = latestData['status']?.toString().trim() ?? '';
      final currentStatus = normalizedStatus(rawCurrentStatus);

      if (currentStatus == 'Delivered') return;

      String nextFromLatest;
      switch (currentStatus) {
        case 'Pending':
          nextFromLatest = 'Confirmed';
          break;
        case 'Confirmed':
          nextFromLatest = 'Preparing';
          break;
        case 'Preparing':
          nextFromLatest = 'Out for Delivery';
          break;
        case 'Out for Delivery':
          nextFromLatest = 'Delivered';
          break;
        default:
          nextFromLatest = currentStatus;
      }

      if (nextFromLatest != next) {
        throw FirebaseException(
          plugin: 'cloud_firestore',
          code: 'failed-precondition',
          message:
              'Order status अभी "$currentStatus" है। Orders screen refresh करके फिर कोशिश करें।',
        );
      }

      final update = <String, dynamic>{
        'status': next,
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (next == 'Out for Delivery') {
        update['pickedUpAt'] = FieldValue.serverTimestamp();
      }

      double deliveryEarning = 0;
      if (next == 'Delivered') {
        update['deliveredAt'] = FieldValue.serverTimestamp();
        deliveryEarning = calculateDeliveryEarning(latestData);
        update['deliveryEarning'] = deliveryEarning;
        update['partnerEarning'] = deliveryEarning;
        update['earning'] = deliveryEarning;
        update['earningGeneratedAt'] = FieldValue.serverTimestamp();
      }

      // Transaction makes the status + earning change atomic. The partner
      // wallet is updated in the same transaction so one delivered order
      // creates exactly one earning entry.
      await db.runTransaction((transaction) async {
        final fresh = await transaction.get(orderRef);
        if (!fresh.exists) {
          throw FirebaseException(
            plugin: 'cloud_firestore',
            code: 'not-found',
            message: 'Order नहीं मिला।',
          );
        }

        final freshData = fresh.data() ?? <String, dynamic>{};
        final freshPartnerId =
            freshData['deliveryPartnerId']?.toString().trim() ?? '';
        final freshStatus = normalizedStatus(
          freshData['status']?.toString() ?? '',
        );

        if (freshPartnerId != user.uid) {
          throw FirebaseException(
            plugin: 'cloud_firestore',
            code: 'permission-denied',
            message: 'यह order अब आपके account को assigned नहीं है।',
          );
        }

        if (freshStatus != currentStatus) {
          throw FirebaseException(
            plugin: 'cloud_firestore',
            code: 'aborted',
            message: 'Order status बदल गया है। Orders screen refresh करें।',
          );
        }

        if (next == 'Delivered') {
          // Firestore transactions must perform all reads before writes.
          final freshPartner = await transaction.get(partnerRef);
          final partnerData = freshPartner.data() ?? <String, dynamic>{};
          final currentTotal = moneyFrom(
            partnerData['totalEarnings'] ??
                partnerData['earnings'] ??
                partnerData['walletBalance'] ??
                0,
          );
          final deliveredRaw = partnerData['deliveredOrderCount'];
          final currentDelivered = deliveredRaw is num
              ? deliveredRaw.toInt()
              : int.tryParse(deliveredRaw?.toString() ?? '') ?? 0;

          // Daily incentive is configured by Admin at incentivePlans/YYYY-MM-DD.
          final now = DateTime.now();
          final dateKey =
              '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
          final incentiveRef = db.collection('incentivePlans').doc(dateKey);
          final incentiveSnap = await transaction.get(incentiveRef);
          final incentivePlan = incentiveSnap.data() ?? <String, dynamic>{};
          final earningWeekStart = flashWeekStart(now);
          final earningWeekKey = flashWeekKey(earningWeekStart);
          final weeklyLedgerRef = db
              .collection('weeklyEarnings')
              .doc('${user.uid}_$earningWeekKey');
          final weeklyLedgerSnap = await transaction.get(weeklyLedgerRef);
          final weeklyLedger = weeklyLedgerSnap.data() ?? <String, dynamic>{};
          final rawTargets = incentivePlan['targets'];
          double newAchievedIncentive = 0.0;
          if (incentivePlan['active'] != false && rawTargets is List) {
            for (final rawTarget in rawTargets) {
              if (rawTarget is! Map) continue;
              final target = Map<String, dynamic>.from(rawTarget);
              final targetOrders = target['orderCount'] is num
                  ? (target['orderCount'] as num).toInt()
                  : int.tryParse(target['orderCount']?.toString() ?? '') ?? 0;
              final targetAmount = moneyFrom(target['amount']);
              if (currentDelivered + 1 >= targetOrders &&
                  targetAmount > newAchievedIncentive) {
                newAchievedIncentive = targetAmount;
              }
            }
          }

          final previousIncentive =
              sameDay(timestampFrom(partnerData['incentiveDate']), now)
              ? moneyFrom(partnerData['incentivePaidToday'])
              : 0.0;
          final incentiveDelta = (newAchievedIncentive - previousIncentive)
              .clamp(0.0, double.infinity)
              .toDouble();
          final newTotal = currentTotal + deliveryEarning + incentiveDelta;

          transaction.set(weeklyLedgerRef, {
            'partnerUid': user.uid,
            'weekKey': earningWeekKey,
            'weekStart': Timestamp.fromDate(earningWeekStart),
            'weekEnd': Timestamp.fromDate(
              earningWeekStart.add(const Duration(days: 7)),
            ),
            'earningAmount':
                moneyFrom(weeklyLedger['earningAmount']) + deliveryEarning,
            'incentiveAmount':
                moneyFrom(weeklyLedger['incentiveAmount']) + incentiveDelta,
            'deliveredOrderCount':
                ((weeklyLedger['deliveredOrderCount'] is num)
                    ? (weeklyLedger['deliveredOrderCount'] as num).toInt()
                    : int.tryParse(
                            '${weeklyLedger['deliveredOrderCount'] ?? 0}',
                          ) ??
                          0) +
                1,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
          transaction.set(partnerRef, {
            'availableForOrder': false,
            'online': false,
            'activeOrderId': FieldValue.delete(),
            'lastDeliveryCompletedAt': FieldValue.serverTimestamp(),
            'lastDeliveryEarning': deliveryEarning,
            'lastIncentiveEarned': incentiveDelta,
            'incentiveDate': dateKey,
            'incentivePaidToday': newAchievedIncentive,
            'totalEarnings': newTotal,
            'walletBalance': newTotal,
            'deliveredOrderCount': currentDelivered + 1,
            'earningsUpdatedAt': FieldValue.serverTimestamp(),
            'autoOfflineAfterDelivery': true,
            'adminOnlineEnabled': false,
            'requiresAdminReactivation': true,
          }, SetOptions(merge: true));
          update['incentiveEarned'] = incentiveDelta;
        }

        transaction.update(orderRef, update);
      });

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Status updated: $next'),
            backgroundColor: green,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } on FirebaseException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Status update नहीं हुआ: ${e.message ?? e.code}'),
            backgroundColor: red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Status update नहीं हुआ: $e'),
            backgroundColor: red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> callCustomer(BuildContext context) async {
    if (customerPhone.isEmpty) return;

    final uri = Uri(scheme: 'tel', path: customerPhone);
    final ok = await launchUrl(uri);

    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Phone app open नहीं हो सका'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> openMap(BuildContext context) async {
    final String url;

    if (hasExactLocation) {
      final lat = deliveryLatitude!.toStringAsFixed(7);
      final lng = deliveryLongitude!.toStringAsFixed(7);
      url =
          'https://www.google.com/maps/dir/?api=1&destination=$lat,$lng&travelmode=driving';
    } else {
      final query = Uri.encodeComponent(address);
      url = 'https://www.google.com/maps/search/?api=1&query=$query';
    }

    final uri = Uri.parse(url);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);

    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Google Maps open नहीं हो सका'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final orderShort = orderId.length > 8
        ? orderId.substring(0, 8).toUpperCase()
        : orderId.toUpperCase();

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(17),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(23),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .05),
            blurRadius: 15,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF1565C0), Color(0xFF42A5F5)],
                  ),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: const Icon(
                  Icons.shopping_bag_rounded,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Order #$orderShort',
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    statusPill(status),
                  ],
                ),
              ),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(
                    '₹${formatMoney(moneyFrom(data['totalPrice'] ?? data['total'] ?? 0))}',
                    maxLines: 1,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Divider(),
          const SizedBox(height: 9),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.person_outline, color: orange),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '$customerName\n${customerPhone.isEmpty ? 'Phone not available' : customerPhone}',
                  style: const TextStyle(height: 1.45),
                ),
              ),
              IconButton(
                onPressed: customerPhone.isEmpty
                    ? null
                    : () => callCustomer(context),
                icon: const Icon(Icons.call_rounded, color: green),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.location_on_outlined, color: orange),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  address,
                  maxLines: compact ? 2 : 5,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(height: 1.45),
                ),
              ),
            ],
          ),
          if (hasExactLocation) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
              decoration: BoxDecoration(
                color: const Color(0xFFF1FAF3),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                children: [
                  Icon(Icons.my_location_rounded, size: 18, color: green),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Customer exact GPS location available',
                      style: TextStyle(
                        color: green,
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 10),
          _partnerOrderItems(items),
          OutlinedButton.icon(
            onPressed: () => openMap(context),
            icon: const Icon(Icons.navigation_rounded),
            label: Text(
              hasExactLocation ? 'Navigate to Customer Location' : 'Navigate',
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: blue,
              side: const BorderSide(color: Color(0xFFDCE6FF)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(13),
              ),
            ),
          ),
          if (!compact && items.isNotEmpty) ...[
            const SizedBox(height: 5),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              title: Text(
                '${items.length} item${items.length == 1 ? '' : 's'}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              children: items.whereType<Map>().map<Widget>((item) {
                final m = Map<String, dynamic>.from(item);
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(m['name']?.toString() ?? 'Product'),
                  subtitle: Text('${m['quantity'] ?? 1} × ₹${m['price'] ?? 0}'),
                  trailing: Text(
                    '₹${m['total'] ?? 0}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                );
              }).toList(),
            ),
          ],
          const SizedBox(height: 9),
          SizedBox(
            width: double.infinity,
            height: 51,
            child: ElevatedButton.icon(
              onPressed: status == 'Delivered'
                  ? null
                  : () => updateStatus(context),
              icon: Icon(
                status == 'Out for Delivery'
                    ? Icons.home_rounded
                    : Icons.arrow_forward_rounded,
              ),
              label: Text(
                status == 'Out for Delivery'
                    ? 'Mark as Delivered'
                    : 'Move to ${nextStatus()}',
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: status == 'Out for Delivery' ? green : orange,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(15),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget statusPill(String value) {
    final color = value == 'Delivered'
        ? green
        : value == 'Cancelled'
        ? red
        : orange;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        value,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _DailyIncentiveCard extends StatelessWidget {
  final int deliveredToday;

  const _DailyIncentiveCard({required this.deliveredToday});

  String _dateKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  double _money(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(
          value?.toString().replaceAll('₹', '').replaceAll(',', '').trim() ??
              '',
        ) ??
        0;
  }

  int _orders(dynamic value) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    final dateKey = _dateKey(DateTime.now());
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('incentivePlans')
          .doc(dateKey)
          .snapshots(),
      builder: (context, snapshot) {
        final plan = snapshot.data?.data();
        final rawTargets = plan?['targets'];
        final targets = rawTargets is List
            ? rawTargets
                  .whereType<Map>()
                  .map((e) => Map<String, dynamic>.from(e))
                  .where((e) => _orders(e['orderCount']) > 0)
                  .toList()
            : <Map<String, dynamic>>[];

        targets.sort(
          (a, b) =>
              _orders(a['orderCount']).compareTo(_orders(b['orderCount'])),
        );

        final planActive = plan?['active'] == true && targets.isNotEmpty;
        double achievedAmount = 0;
        Map<String, dynamic>? next;

        if (planActive) {
          for (final target in targets) {
            final count = _orders(target['orderCount']);
            final amount = _money(target['amount']);
            if (deliveredToday >= count) {
              if (amount > achievedAmount) achievedAmount = amount;
            } else if (next == null) {
              next = target;
            }
          }
        }

        final nextOrders = next == null ? 0 : _orders(next['orderCount']);
        final nextAmount = next == null ? 0.0 : _money(next['amount']);
        final remaining = next == null ? 0 : nextOrders - deliveredToday;

        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFFFFF4E8), Colors.white],
            ),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: orange.withValues(alpha: .18)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: orange.withValues(alpha: .12),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.emoji_events_rounded,
                      color: orange,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      "Today's Incentive",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  Text(
                    '₹${formatMoney(achievedAmount)}',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      color: orange,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (planActive) ...[
                Text(
                  plan?['title']?.toString().trim().isNotEmpty == true
                      ? plan!['title'].toString()
                      : 'आज का incentive target',
                  style: const TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 6),
                Text(
                  next == null
                      ? 'आज के सभी incentive targets पूरे हो गए 🎉'
                      : '$remaining और orders पूरे करें → ₹${formatMoney(nextAmount)} incentive',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: targets.map((target) {
                    final count = _orders(target['orderCount']);
                    final amount = _money(target['amount']);
                    final done = deliveredToday >= count;
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: done
                            ? green.withValues(alpha: .10)
                            : Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: done
                              ? green.withValues(alpha: .25)
                              : Colors.grey.shade200,
                        ),
                      ),
                      child: Text(
                        '$count orders • ₹${formatMoney(amount)}${done ? ' ✓' : ''}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: done ? green : dark,
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ] else ...[
                const SizedBox(height: 8),
                const Text(
                  'आज के लिए Admin ने अभी incentive plan active नहीं किया है.',
                  style: TextStyle(
                    color: Color(0xFF6B7280),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  'Completed orders today: $deliveredToday',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

DateTime flashWeekStart([DateTime? value]) {
  final d = value ?? DateTime.now();
  final local = DateTime(d.year, d.month, d.day);
  return local.subtract(Duration(days: local.weekday - DateTime.monday));
}

DateTime flashWeekEnd([DateTime? value]) =>
    flashWeekStart(value).add(const Duration(days: 7));
String flashWeekKey(DateTime d) {
  final x = flashWeekStart(d);
  return '${x.year.toString().padLeft(4, '0')}-${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')}';
}

DateTime? flashDate(dynamic v) {
  if (v is Timestamp) return v.toDate();
  if (v is DateTime) return v;
  if (v is String) return DateTime.tryParse(v);
  return null;
}

double flashMoney(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String)
    return double.tryParse(v.replaceAll(',', '').replaceAll('₹', '').trim()) ??
        0;
  return 0;
}

double flashOrderSales(Map<String, dynamic> d) {
  for (final k in [
    'totalAmount',
    'grandTotal',
    'orderTotal',
    'total',
    'amount',
    'payableAmount',
    'finalAmount',
  ]) {
    final v = flashMoney(d[k]);
    if (v > 0) return v;
  }
  double sum = 0;
  final items = d['items'] ?? d['cartItems'] ?? d['products'];
  if (items is List) {
    for (final raw in items) {
      if (raw is! Map) continue;
      final price = flashMoney(
        raw['sellingPrice'] ??
            raw['price'] ??
            raw['unitPrice'] ??
            raw['salePrice'],
      );
      final qty = flashMoney(
        raw['quantity'] ?? raw['qty'] ?? raw['count'] ?? 1,
      );
      sum += price * (qty <= 0 ? 1 : qty);
    }
  }
  return sum;
}

bool flashDelivered(Map<String, dynamic> d) =>
    (d['status'] ?? '').toString().trim().toLowerCase() == 'delivered';
DateTime? flashDeliveredDate(Map<String, dynamic> d) => flashDate(
  d['deliveredAt'] ?? d['updatedAt'] ?? d['orderDate'] ?? d['createdAt'],
);
double flashDeliveryEarning(Map<String, dynamic> d) =>
    flashMoney(d['deliveryEarning'] ?? d['partnerEarning'] ?? d['earning']);

class EarningsPage extends StatefulWidget {
  const EarningsPage({super.key});
  @override
  State<EarningsPage> createState() => _EarningsPageState();
}

class _EarningsPageState extends State<EarningsPage> {
  User? get user => FirebaseAuth.instance.currentUser;
  @override
  Widget build(BuildContext context) {
    final u = user;
    if (u == null)
      return const ColoredBox(
        color: bg,
        child: Center(child: Text('Please login again.')),
      );
    final db = FirebaseFirestore.instance;
    // Clamp system text scaling for the complete Earnings/Payout screen.
    // This fixes oversized headings, dates, amounts and empty-state messages.
    return Theme(
      data: Theme.of(context).copyWith(
        textTheme: Theme.of(context).textTheme.apply(fontSizeFactor: 0.75),
      ),
      child: MediaQuery(
        data: MediaQuery.of(context).copyWith(
          // Force a compact scale for this screen, independent of device text size.
          textScaler: const TextScaler.linear(0.70),
        ),
        child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: db
              .collection('orders')
              .where('deliveryPartnerId', isEqualTo: u.uid)
              .snapshots(),
          builder: (context, snapshot) {
            if (snapshot.hasError)
              return Container(
                color: bg,
                child: _StreamErrorView(
                  message: 'Earnings load नहीं हो सकी',
                  error: snapshot.error,
                ),
              );
            if (!snapshot.hasData)
              return const ColoredBox(
                color: bg,
                child: Center(child: CircularProgressIndicator(color: orange)),
              );
            final docs = snapshot.data!.docs
                .where((doc) => flashDelivered(doc.data()))
                .toList();
            final now = DateTime.now(),
                start = flashWeekStart(now),
                end = flashWeekEnd(now);
            final current = docs.where((doc) {
              final dt = flashDeliveredDate(doc.data());
              return dt != null && !dt.isBefore(start) && dt.isBefore(end);
            }).toList();
            final currentTotal = current.fold<double>(
              0,
              (sum, doc) =>
                  sum +
                  moneyFrom(
                    doc.data()['deliveryEarning'] ??
                        doc.data()['partnerEarning'] ??
                        doc.data()['earning'] ??
                        calculateDeliveryEarning(doc.data()),
                  ),
            );
            final todayTotal = docs
                .where((doc) {
                  final d = doc.data();
                  final dt = timestampFrom(d['deliveredAt']);
                  return dt != null && sameDay(dt, now);
                })
                .fold<double>(
                  0,
                  (sum, doc) =>
                      sum +
                      moneyFrom(
                        doc.data()['deliveryEarning'] ??
                            doc.data()['partnerEarning'] ??
                            doc.data()['earning'] ??
                            calculateDeliveryEarning(doc.data()),
                      ),
                );
            final grouped = <String, Map<String, dynamic>>{};
            for (final doc in docs) {
              final d = doc.data();
              final dt = flashDeliveredDate(d);
              if (dt == null) continue;
              final wk = flashWeekStart(dt);
              final key = flashWeekKey(wk);
              final row = grouped.putIfAbsent(
                key,
                () => {'start': wk, 'total': 0.0, 'count': 0},
              );
              row['total'] =
                  (row['total'] as double) +
                  moneyFrom(
                    d['deliveryEarning'] ??
                        d['partnerEarning'] ??
                        d['earning'] ??
                        calculateDeliveryEarning(d),
                  );
              row['count'] = (row['count'] as int) + 1;
            }
            final history = grouped.entries.toList()
              ..sort(
                (a, b) => (b.value['start'] as DateTime).compareTo(
                  a.value['start'] as DateTime,
                ),
              );
            return Container(
              color: const Color(0xFFEAF2FF), // light blue page background
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
                children: [
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(colors: [orange, orange2]),
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Current Week Earnings',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            decoration: TextDecoration.none,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '₹${currentTotal.toStringAsFixed(2)}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 32,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${flashWeekKey(start)} से ${flashWeekKey(end)} तक',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            decoration: TextDecoration.none,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: _weeklyStat(
                                'Today',
                                '₹${todayTotal.toStringAsFixed(2)}',
                              ),
                            ),
                            Expanded(
                              child: _weeklyStat(
                                'Delivered orders',
                                '${current.length}',
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'Weekly Payout History',
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                      color: dark,
                      decoration: TextDecoration.none,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (history.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: MediaQuery(
                        data: MediaQuery.of(context)
                            .copyWith(textScaler: const TextScaler.linear(1.0)),
                        child: const Text(
                          'अभी delivered earning history उपलब्ध नहीं है.',
                          style: TextStyle(
                            fontSize: 16,
                            height: 1.45,
                            color: Color(0xFF707070),
                            fontWeight: FontWeight.w400,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ),
                    ),
                  ...history.map((entry) {
                    final d = entry.value;
                    final week = entry.key;
                    final amount = d['total'] as double;
                    return Card(
                      child: ListTile(
                        leading: const CircleAvatar(
                          backgroundColor: Color(0xFFFFF0E9),
                          child: Icon(Icons.calendar_month, color: orange),
                        ),
                        title: Text(
                          'Week $week',
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        subtitle: Text(
                          '${d['count']} delivered orders • ₹${amount.toStringAsFixed(2)}',
                        ),
                        trailing: week == flashWeekKey(start)
                            ? const Text(
                                'CURRENT',
                                style: TextStyle(
                                  color: orange,
                                  fontWeight: FontWeight.bold,
                                ),
                              )
                            : null,
                      ),
                    );
                  }),
                  const SizedBox(height: 18),
                  const Text(
                    'Saved Weekly Earnings History',
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                      color: dark,
                      decoration: TextDecoration.none,
                    ),
                  ),
                  StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream: db
                        .collection('weeklyEarnings')
                        .where('partnerUid', isEqualTo: u.uid)
                        .snapshots(),
                    builder: (context, ws) {
                      if (ws.hasError)
                        return Text('Weekly history load error: ${ws.error}');
                      if (!ws.hasData) return const LinearProgressIndicator();
                      final rows = [...ws.data!.docs]
                        ..sort(
                          (a, b) =>
                              (flashDate(b.data()['weekStart']) ??
                                      DateTime(1970))
                                  .compareTo(
                                    flashDate(a.data()['weekStart']) ??
                                        DateTime(1970),
                                  ),
                        );
                      if (rows.isEmpty)
                        return Padding(
                          padding: const EdgeInsets.all(12),
                          child: MediaQuery(
                            data: MediaQuery.of(context).copyWith(
                              textScaler: const TextScaler.linear(1.0),
                            ),
                            child: const Text(
                              'नए delivered orders के बाद saved weekly history यहाँ दिखेगी.',
                              style: TextStyle(
                                fontSize: 16,
                                height: 1.45,
                                color: Color(0xFF707070),
                                fontWeight: FontWeight.w400,
                                decoration: TextDecoration.none,
                              ),
                            ),
                          ),
                        );
                      return Column(
                        children: rows.map((doc) {
                          final d = doc.data();
                          return Card(
                            child: ListTile(
                              title: Text('Week ${d['weekKey'] ?? ''}'),
                              subtitle: Text(
                                '${d['deliveredOrderCount'] ?? 0} delivered orders • Earnings ₹${moneyFrom(d['earningAmount']).toStringAsFixed(2)} • Incentive ₹${moneyFrom(d['incentiveAmount']).toStringAsFixed(2)}',
                              ),
                            ),
                          );
                        }).toList(),
                      );
                    },
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'Payout Status',
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                      color: dark,
                      decoration: TextDecoration.none,
                    ),
                  ),
                  StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream: db
                        .collection('weeklyPayouts')
                        .where('recipientType', isEqualTo: 'deliveryPartner')
                        .where('recipientUid', isEqualTo: u.uid)
                        .snapshots(),
                    builder: (context, ps) {
                      if (ps.hasError)
                        return Text('Payout status load error: ${ps.error}');
                      if (!ps.hasData) return const LinearProgressIndicator();
                      final rows = [...ps.data!.docs]
                        ..sort(
                          (a, b) =>
                              (flashDate(b.data()['weekStart']) ??
                                      DateTime(1970))
                                  .compareTo(
                                    flashDate(a.data()['weekStart']) ??
                                        DateTime(1970),
                                  ),
                        );
                      if (rows.isEmpty)
                        return MediaQuery(
                          // Keep this empty-state message readable even if the
                          // device/app text scale is set unusually large.
                          data: MediaQuery.of(
                            context,
                          ).copyWith(textScaler: const TextScaler.linear(1.0)),
                          child: const Padding(
                            padding: EdgeInsets.all(12),
                            child: Text(
                              'अभी payout status दर्ज नहीं है. आपकी weekly earning ऊपर दिख रही है.',
                              textScaler: TextScaler.linear(1.0),
                              style: TextStyle(
                                fontSize: 16,
                                height: 1.45,
                                color: Color(0xFF707070),
                                fontWeight: FontWeight.normal,
                                decoration: TextDecoration.none,
                              ),
                            ),
                          ),
                        );
                      return Column(
                        children: rows.map((doc) {
                          final d = doc.data();
                          return Card(
                            child: ListTile(
                              title: Text('Week ${d['weekKey'] ?? ''}'),
                              subtitle: Text(
                                '₹${flashMoney(d['totalEarning'] ?? d['amount']).toStringAsFixed(2)}${(d['paymentReference'] ?? '').toString().isNotEmpty ? ' • Ref: ${d['paymentReference']}' : ''}',
                              ),
                              trailing: Text(
                                (d['status'] ?? 'Pending').toString(),
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: d['status'] == 'Paid' ? green : orange,
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      );
                    },
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

Widget _weeklyStat(String label, String value) => Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    Text(label, style: const TextStyle(color: Colors.white70, fontSize: 14)),
    const SizedBox(height: 4),
    Text(
      value,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 20,
        fontWeight: FontWeight.w900,
      ),
    ),
  ],
);

/// Lets a signed-in delivery partner update only their own vehicle and area
/// details. Existing approval, online, assignment and payout fields are left
/// untouched by using a merge write with only the editable profile fields.
Future<void> showEditPartnerDetails(BuildContext context) async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('पहले login करें।')));
    return;
  }

  final partnerRef = FirebaseFirestore.instance
      .collection('deliveryPartners')
      .doc(user.uid);

  Map<String, dynamic> profile = <String, dynamic>{};
  try {
    final snapshot = await partnerRef.get();
    if (snapshot.exists) {
      profile = snapshot.data() ?? <String, dynamic>{};
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Profile load नहीं हो सकी: $e')));
    }
    return;
  }

  if (!context.mounted) return;

  final vehicleController = TextEditingController(
    text: (profile['vehicle'] ?? '').toString(),
  );
  final vehicleNumberController = TextEditingController(
    text: (profile['vehicleNumber'] ?? '').toString(),
  );
  final areaController = TextEditingController(
    text: (profile['area'] ?? '').toString(),
  );
  const vehicleOptions = <String>[
    'Bike',
    'Scooter',
    'Electric Scooter',
    'Cycle',
    'Other',
  ];
  String selectedVehicle = vehicleOptions.contains(vehicleController.text)
      ? vehicleController.text
      : (vehicleController.text.isEmpty ? 'Bike' : 'Other');
  bool saving = false;

  try {
    await showDialog<void>(
      context: context,
      barrierDismissible: !saving,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text(
            'Edit Vehicle / Area Details',
            style: TextStyle(fontWeight: FontWeight.w900),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  value: selectedVehicle,
                  decoration: inputDecoration(
                    'Vehicle Type',
                    Icons.directions_bike_rounded,
                  ),
                  items: vehicleOptions
                      .map(
                        (value) => DropdownMenuItem<String>(
                          value: value,
                          child: Text(value),
                        ),
                      )
                      .toList(),
                  onChanged: saving
                      ? null
                      : (value) {
                          if (value != null) {
                            setDialogState(() => selectedVehicle = value);
                          }
                        },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: vehicleNumberController,
                  textCapitalization: TextCapitalization.characters,
                  decoration: inputDecoration(
                    'Vehicle Number',
                    Icons.confirmation_number_outlined,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: areaController,
                  textCapitalization: TextCapitalization.words,
                  decoration: inputDecoration(
                    'Delivery Area',
                    Icons.location_on_outlined,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      final vehicleNumber = vehicleNumberController.text
                          .trim()
                          .toUpperCase();
                      final area = areaController.text.trim();
                      if (vehicleNumber.length < 3 || area.length < 2) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Vehicle Number और Delivery Area सही दर्ज करें।',
                            ),
                          ),
                        );
                        return;
                      }

                      setDialogState(() => saving = true);
                      try {
                        await partnerRef.set({
                          'vehicle': selectedVehicle,
                          'vehicleNumber': vehicleNumber,
                          'area': area,
                          'updatedAt': FieldValue.serverTimestamp(),
                        }, SetOptions(merge: true));

                        if (dialogContext.mounted) {
                          Navigator.pop(dialogContext);
                        }
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Vehicle details सफलतापूर्वक save हुए।',
                              ),
                            ),
                          );
                        }
                      } catch (e) {
                        setDialogState(() => saving = false);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Save नहीं हो सका: $e')),
                          );
                        }
                      }
                    },
              child: saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save Changes'),
            ),
          ],
        ),
      ),
    );
  } finally {
    vehicleController.dispose();
    vehicleNumberController.dispose();
    areaController.dispose();
  }
}

// ============================================================
// DELIVERY PARTNER PERFORMANCE + RATING RANK
// ============================================================
// Rank is calculated from delivered orders and customer ratings.
// Thresholds are app-side defaults and can be adjusted to the business policy.
class PartnerPerformanceSection extends StatelessWidget {
  final String partnerId;
  const PartnerPerformanceSection({super.key, required this.partnerId});

  static const List<Map<String, dynamic>> _tiers = [
    {
      'name': 'CROWN DIAMOND PARTNER',
      'orders': 2000,
      'rating': 4.8,
      'color': Color(0xFF6D28D9),
      'icon': Icons.workspace_premium_rounded,
    },
    {
      'name': 'DOUBLE DIAMOND PARTNER',
      'orders': 1000,
      'rating': 4.7,
      'color': Color(0xFF2563EB),
      'icon': Icons.diamond_rounded,
    },
    {
      'name': 'DIAMOND PARTNER',
      'orders': 500,
      'rating': 4.5,
      'color': Color(0xFF0891B2),
      'icon': Icons.diamond_outlined,
    },
    {
      'name': 'GOLD PARTNER',
      'orders': 200,
      'rating': 4.2,
      'color': Color(0xFFD97706),
      'icon': Icons.workspace_premium_rounded,
    },
    {
      'name': 'SILVER PARTNER',
      'orders': 50,
      'rating': 4.0,
      'color': Color(0xFF64748B),
      'icon': Icons.military_tech_rounded,
    },
    {
      'name': 'BRONZE PARTNER',
      'orders': 0,
      'rating': 0.0,
      'color': Color(0xFF92400E),
      'icon': Icons.shield_rounded,
    },
  ];

  Map<String, dynamic> _tierFor(int orders, double rating) {
    for (final tier in _tiers) {
      if (orders >= (tier['orders'] as int) &&
          rating >= (tier['rating'] as double)) {
        return tier;
      }
    }
    return _tiers.last;
  }

  Map<String, dynamic>? _nextTier(String currentName) {
    final index = _tiers.indexWhere((tier) => tier['name'] == currentName);
    if (index <= 0) return null;
    return _tiers[index - 1];
  }

  @override
  Widget build(BuildContext context) {
    final db = FirebaseFirestore.instance;
    final ordersStream = db
        .collection('orders')
        .where('deliveryPartnerId', isEqualTo: partnerId)
        .snapshots();
    final ratingsStream = db
        .collection('deliveryRatings')
        .where('partnerId', isEqualTo: partnerId)
        .snapshots();

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: ordersStream,
      builder: (context, orderSnapshot) {
        if (orderSnapshot.hasError) {
          return _performanceErrorCard('Delivered orders load नहीं हो सके');
        }
        if (orderSnapshot.connectionState == ConnectionState.waiting) {
          return const Card(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Center(child: CircularProgressIndicator(color: orange)),
            ),
          );
        }

        final deliveredCount = orderSnapshot.data!.docs.where((doc) {
          return (doc.data()['status'] ?? '').toString().trim().toLowerCase() ==
              'delivered';
        }).length;

        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: ratingsStream,
          builder: (context, ratingSnapshot) {
            if (ratingSnapshot.hasError) {
              return _performanceErrorCard(
                'Ratings load नहीं हो सकीं। Firestore rules जाँचें।',
              );
            }
            final ratingDocs = ratingSnapshot.data?.docs ?? [];
            double totalStars = 0;
            int validRatings = 0;
            for (final doc in ratingDocs) {
              final raw = doc.data()['stars'];
              final stars = raw is num
                  ? raw.toDouble()
                  : double.tryParse(raw?.toString() ?? '') ?? 0;
              if (stars >= 1 && stars <= 5) {
                totalStars += stars;
                validRatings++;
              }
            }
            final average = validRatings == 0 ? 0.0 : totalStars / validRatings;
            final tier = _tierFor(deliveredCount, average);
            final next = _nextTier(tier['name'] as String);
            final tierColor = tier['color'] as Color;
            final ordersNeeded = next == null
                ? 0
                : ((next['orders'] as int) - deliveredCount).clamp(0, 999999);
            final ratingNeeded = next == null
                ? 0.0
                : (next['rating'] as double);

            return Card(
              elevation: 0,
              color: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(22),
                side: BorderSide(color: tierColor.withValues(alpha: .25)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            color: tierColor.withValues(alpha: .12),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Icon(
                            tier['icon'] as IconData,
                            color: tierColor,
                            size: 30,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'YOUR PERFORMANCE RANK',
                                style: TextStyle(
                                  color: grey,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: .8,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                tier['name'] as String,
                                style: TextStyle(
                                  color: tierColor,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: _performanceMetric(
                            icon: Icons.task_alt_rounded,
                            label: 'Delivered Orders',
                            value: '$deliveredCount',
                            color: green,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _performanceMetric(
                            icon: Icons.star_rounded,
                            label: 'Customer Rating',
                            value: validRatings == 0
                                ? 'No rating'
                                : '${average.toStringAsFixed(1)} / 5',
                            color: yellow,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '$validRatings customer rating${validRatings == 1 ? '' : 's'} received',
                      style: const TextStyle(color: grey, fontSize: 12),
                    ),
                    if (ratingDocs.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      const Text(
                        'RECENT CUSTOMER REVIEWS',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 11,
                          letterSpacing: .6,
                        ),
                      ),
                      const SizedBox(height: 4),
                      ...(() {
                        final recent = [...ratingDocs];
                        recent.sort((a, b) {
                          final at = a.data()['createdAt'];
                          final bt = b.data()['createdAt'];
                          final ad = at is Timestamp
                              ? at.toDate()
                              : DateTime.fromMillisecondsSinceEpoch(0);
                          final bd = bt is Timestamp
                              ? bt.toDate()
                              : DateTime.fromMillisecondsSinceEpoch(0);
                          return bd.compareTo(ad);
                        });
                        return recent.take(5).map((doc) {
                          final reviewData = doc.data();
                          final customer =
                              (reviewData['customerName'] ?? 'Customer')
                                  .toString();
                          final review = (reviewData['review'] ?? '')
                              .toString()
                              .trim();
                          final rawStars = reviewData['stars'];
                          final stars = rawStars is num
                              ? rawStars.toInt()
                              : int.tryParse(rawStars?.toString() ?? '') ?? 0;
                          return Container(
                            margin: const EdgeInsets.only(top: 7),
                            padding: const EdgeInsets.all(11),
                            decoration: BoxDecoration(
                              color: bg,
                              borderRadius: BorderRadius.circular(13),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        customer,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      '★' * stars,
                                      style: const TextStyle(
                                        color: Color(0xFFF4B400),
                                        fontSize: 15,
                                      ),
                                    ),
                                  ],
                                ),
                                if (review.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    review,
                                    style: const TextStyle(
                                      color: dark,
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          );
                        }).toList();
                      })(),
                    ],
                    if (next != null) ...[
                      const SizedBox(height: 14),
                      const Divider(),
                      Text(
                        'Next rank: ${next['name']}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        'Requirement: ${next['orders']} delivered orders and ${ratingNeeded.toStringAsFixed(1)}★ average rating.',
                        style: const TextStyle(color: grey, fontSize: 12),
                      ),
                      if (ordersNeeded > 0)
                        Text(
                          '$ordersNeeded more delivered order${ordersNeeded == 1 ? '' : 's'} needed for the order target.',
                          style: TextStyle(
                            color: tierColor,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      if (average < ratingNeeded && validRatings > 0)
                        Text(
                          'Rating target पूरा करने के लिए customer service बेहतर रखें.',
                          style: TextStyle(
                            color: tierColor,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                    ] else ...[
                      const SizedBox(height: 12),
                      const Text(
                        'Highest rank achieved — शानदार काम!',
                        style: TextStyle(
                          color: green,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                    const SizedBox(height: 14),
                    const Text(
                      'PARTNER RANK LEVELS',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 11,
                        letterSpacing: .6,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: _tiers.reversed.map((item) {
                        final isCurrent = item['name'] == tier['name'];
                        return Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 7,
                          ),
                          decoration: BoxDecoration(
                            color: isCurrent
                                ? (item['color'] as Color)
                                : (item['color'] as Color).withValues(
                                    alpha: .08,
                                  ),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: (item['color'] as Color).withValues(
                                alpha: .35,
                              ),
                            ),
                          ),
                          child: Text(
                            (item['name'] as String).replaceAll(' PARTNER', ''),
                            style: TextStyle(
                              color: isCurrent
                                  ? Colors.white
                                  : item['color'] as Color,
                              fontSize: 10,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Rank calculation: delivered orders + customer rating. Orders that are cancelled are not counted.',
                      style: TextStyle(
                        color: grey.withValues(alpha: .95),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _performanceErrorCard(String message) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Text(message, style: const TextStyle(color: red)),
    ),
  );

  Widget _performanceMetric({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(15),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(height: 7),
          Text(
            value,
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
          ),
          Text(label, style: const TextStyle(color: grey, fontSize: 11)),
        ],
      ),
    );
  }
}

class PartnerProfilePage extends StatefulWidget {
  const PartnerProfilePage({super.key});

  @override
  State<PartnerProfilePage> createState() => _PartnerProfilePageState();
}

class _PartnerProfilePageState extends State<PartnerProfilePage> {
  final ImagePicker _picker = ImagePicker();
  bool uploadingPhoto = false;

  Future<void> changePhoto() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt_rounded),
              title: const Text('Take Selfie / Photo'),
              onTap: () => Navigator.pop(c, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_rounded),
              title: const Text('Choose from Gallery'),
              onTap: () => Navigator.pop(c, 'gallery'),
            ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    final picked = await _picker.pickImage(
      source: choice == 'camera' ? ImageSource.camera : ImageSource.gallery,
      maxWidth: 900,
      maxHeight: 900,
      imageQuality: 55,
    );
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    if (bytes.length > 650000) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Photo बहुत बड़ी है. दूसरी photo चुनें.'),
          ),
        );
      return;
    }
    setState(() => uploadingPhoto = true);
    try {
      await FirebaseFirestore.instance
          .collection('deliveryPartners')
          .doc(FirebaseAuth.instance.currentUser!.uid)
          .set({
            'profilePhotoBase64': base64Encode(bytes),
            'profilePhotoUpdatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Profile photo updated ✓'),
            backgroundColor: green,
          ),
        );
    } finally {
      if (mounted) setState(() => uploadingPhoto = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser!;
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('deliveryPartners')
          .doc(user.uid)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError)
          return _StreamErrorView(
            message: 'Profile load नहीं हुई',
            error: snapshot.error,
          );
        if (snapshot.connectionState == ConnectionState.waiting)
          return const Center(child: CircularProgressIndicator(color: orange));
        final data = snapshot.data?.data() ?? {};
        final name = data['name']?.toString();
        final displayName = name == null || name.trim().isEmpty
            ? 'Delivery Partner'
            : name;
        final photo = data['profilePhotoBase64']?.toString() ?? '';
        ImageProvider? photoProvider;
        if (photo.isNotEmpty) {
          try {
            photoProvider = MemoryImage(base64Decode(photo));
          } catch (_) {}
        }
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [orange, orange2]),
                borderRadius: BorderRadius.circular(26),
              ),
              child: Column(
                children: [
                  Stack(
                    alignment: Alignment.bottomRight,
                    children: [
                      CircleAvatar(
                        radius: 48,
                        backgroundColor: Colors.white,
                        backgroundImage: photoProvider,
                        child: photoProvider == null
                            ? const Icon(
                                Icons.delivery_dining_rounded,
                                size: 47,
                                color: orange,
                              )
                            : null,
                      ),
                      InkWell(
                        onTap: uploadingPhoto ? null : changePhoto,
                        child: Container(
                          padding: const EdgeInsets.all(9),
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                          ),
                          child: uploadingPhoto
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(
                                  Icons.camera_alt_rounded,
                                  size: 20,
                                  color: dark,
                                ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    displayName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 23,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    data['phone']?.toString() ?? user.phoneNumber ?? '',
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 13,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: .18),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      data['online'] == true ? '● ONLINE' : '● OFFLINE',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            PartnerPerformanceSection(partnerId: user.uid),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: uploadingPhoto ? null : changePhoto,
              icon: const Icon(Icons.add_a_photo_rounded),
              label: const Text('Change Profile Photo / Upload Selfie'),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 52,
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const DeliveryAssetsPage()),
                ),
                icon: const Icon(Icons.inventory_2_rounded),
                label: const Text(
                  'Assets / Store Items',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
            ),
            const SizedBox(height: 8),
            infoTile(
              'Vehicle',
              data['vehicle']?.toString() ?? 'Not added',
              Icons.two_wheeler_rounded,
              blue,
            ),
            infoTile(
              'Vehicle Number',
              data['vehicleNumber']?.toString() ?? 'Not added',
              Icons.confirmation_number_outlined,
              purple,
            ),
            infoTile(
              'Area',
              data['area']?.toString() ?? 'Not added',
              Icons.location_city_outlined,
              orange,
            ),
            infoTile(
              'Partner Status',
              data['active'] == false ? 'Inactive' : 'Active',
              Icons.verified_user_outlined,
              data['active'] == false ? red : green,
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: 52,
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: orange,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                onPressed: () => showEditPartnerDetails(context),
                icon: const Icon(Icons.edit_rounded),
                label: const Text(
                  'Edit Vehicle / Area Details',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

Widget infoTile(String title, String value, IconData icon, Color color) {
  return Container(
    margin: const EdgeInsets.only(bottom: 11),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
    ),
    child: Row(
      children: [
        CircleAvatar(
          backgroundColor: color.withValues(alpha: .10),
          child: Icon(icon, color: color),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(color: Colors.grey)),
              const SizedBox(height: 3),
              Text(value, style: const TextStyle(fontWeight: FontWeight.w900)),
            ],
          ),
        ),
      ],
    ),
  );
}

class DeliveryAssetsPage extends StatelessWidget {
  const DeliveryAssetsPage({super.key});

  Future<void> requestAsset(
    BuildContext context,
    Map<String, dynamic> asset,
  ) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final partner = await FirebaseFirestore.instance
        .collection('deliveryPartners')
        .doc(user.uid)
        .get();
    final p = partner.data() ?? {};
    await FirebaseFirestore.instance.collection('deliveryAssetRequests').add({
      'partnerId': user.uid,
      'partnerName': p['name']?.toString() ?? 'Delivery Partner',
      'partnerPhone': p['phone']?.toString() ?? user.phoneNumber ?? '',
      'assetId': asset['id'],
      'assetName': asset['name'],
      'price': asset['price'],
      'status': 'Pending',
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    if (context.mounted)
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Asset request sent to Admin ✓'),
          backgroundColor: green,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Assets / Store Items',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('deliveryAssets')
            .where('available', isEqualTo: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError)
            return const Center(child: Text('Assets load नहीं हुए.'));
          if (!snapshot.hasData)
            return const Center(
              child: CircularProgressIndicator(color: orange),
            );
          var docs = snapshot.data!.docs;
          if (docs.isEmpty) {
            return const Center(
              child: Text('Assets अभी Admin द्वारा add नहीं किए गए हैं.'),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: const Text(
                  'Useful delivery items • ₹69 से ₹199 के बीच',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(height: 12),
              ...docs.map((d) {
                final a = d.data();
                final x = {...a, 'id': d.id};
                return Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: orange.withValues(alpha: .10),
                      child: Text(
                        a['icon']?.toString() ?? '📦',
                        style: const TextStyle(fontSize: 22),
                      ),
                    ),
                    title: Text(
                      a['name']?.toString() ?? 'Asset',
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                    subtitle: Text('₹${a['price'] ?? 0}'),
                    trailing: FilledButton(
                      onPressed: () => requestAsset(context, x),
                      child: const Text('Request'),
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

class DeliveryHelpPage extends StatelessWidget {
  const DeliveryHelpPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Help & Delivery Guide',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          _HelpCard(
            icon: Icons.power_settings_new_rounded,
            title: 'Go Online',
            text: 'Home screen पर Online switch ON करें। Available होने पर आपको orders मिल सकते हैं.',
          ),
          _HelpCard(
            icon: Icons.receipt_long_rounded,
            title: 'New Order',
            text: 'Assigned order Orders tab और Home screen पर दिखाई देगा। Customer और delivery address देखकर Navigate करें.',
          ),
          _HelpCard(
            icon: Icons.call_rounded,
            title: 'Customer Contact',
            text: 'Order card में call button से customer को सीधे call कर सकते हैं.',
          ),
          _HelpCard(
            icon: Icons.navigation_rounded,
            title: 'Navigation',
            text:
                'Navigate button customer address को Google Maps में खोलता है.',
          ),
          _HelpCard(
            icon: Icons.check_circle_outline_rounded,
            title: 'Complete Delivery',
            text: 'Order pickup के बाद status को आगे बढ़ाएँ और delivery complete होने पर Mark as Delivered करें.',
          ),
          _HelpCard(
            icon: Icons.support_agent_rounded,
            title: 'Problem?',
            text: 'Menu → Customer Support / Complaint से issue submit करें. Order ID देना हो तो साथ में डालें.',
          ),
        ],
      ),
    );
  }
}

class _HelpCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String text;

  const _HelpCard({
    required this.icon,
    required this.title,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(17),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(19),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            backgroundColor: const Color(0xFFFFEEE8),
            child: Icon(icon, color: orange),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  text,
                  style: const TextStyle(color: Colors.grey, height: 1.45),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class DeliveryTrainingPage extends StatelessWidget {
  const DeliveryTrainingPage({super.key});

  Future<void> _openVideo(BuildContext context, String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Training video link सही नहीं है.')),
        );
      }
      return;
    }

    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Video open नहीं हो सका.')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Video open नहीं हो सका: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Training Videos',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('deliveryTrainingVideos')
            .where('published', isEqualTo: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Training videos load नहीं हो सके.\n${snapshot.error}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: red),
                ),
              ),
            );
          }

          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(color: orange),
            );
          }

          final docs = [...snapshot.data!.docs];
          docs.sort((a, b) {
            final ao = moneyFrom(a.data()['sortOrder'] ?? 0);
            final bo = moneyFrom(b.data()['sortOrder'] ?? 0);
            return ao.compareTo(bo);
          });

          if (docs.isEmpty) {
            return ListView(
              padding: const EdgeInsets.all(20),
              children: const [
                SizedBox(height: 40),
                Icon(Icons.ondemand_video_rounded, size: 64, color: orange),
                SizedBox(height: 14),
                Text(
                  'Training videos जल्द उपलब्ध होंगे.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
                ),
                SizedBox(height: 8),
                Text(
                  'Admin से video publish होने के बाद वे यहाँ दिखाई देंगे.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey, height: 1.4),
                ),
              ],
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
            itemCount: docs.length,
            itemBuilder: (context, index) {
              final data = docs[index].data();
              final title = data['title']?.toString().trim().isNotEmpty == true
                  ? data['title'].toString()
                  : 'Training Video ${index + 1}';
              final description = data['description']?.toString() ?? '';
              final duration = data['duration']?.toString() ?? '';
              final videoUrl = data['videoUrl']?.toString() ?? '';
              final thumbnailUrl = data['thumbnailUrl']?.toString() ?? '';

              return Container(
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFFE5E7EB)),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x0A000000),
                      blurRadius: 12,
                      offset: Offset(0, 5),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (thumbnailUrl.isNotEmpty)
                      ClipRRect(
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(20),
                        ),
                        child: Image.network(
                          thumbnailUrl,
                          height: 170,
                          width: double.infinity,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const SizedBox(
                            height: 170,
                            child: Center(
                              child: Icon(
                                Icons.ondemand_video_rounded,
                                size: 50,
                                color: orange,
                              ),
                            ),
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const CircleAvatar(
                                backgroundColor: Color(0xFFFFEEE8),
                                child: Icon(
                                  Icons.play_circle_fill_rounded,
                                  color: orange,
                                ),
                              ),
                              const SizedBox(width: 11),
                              Expanded(
                                child: Text(
                                  title,
                                  style: const TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ),
                              if (duration.isNotEmpty)
                                Text(
                                  duration,
                                  style: const TextStyle(
                                    color: Colors.grey,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                            ],
                          ),
                          if (description.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            Text(
                              description,
                              style: const TextStyle(
                                color: Color(0xFF6B7280),
                                height: 1.4,
                              ),
                            ),
                          ],
                          const SizedBox(height: 13),
                          SizedBox(
                            width: double.infinity,
                            height: 48,
                            child: ElevatedButton.icon(
                              onPressed: videoUrl.isEmpty
                                  ? null
                                  : () => _openVideo(context, videoUrl),
                              icon: const Icon(Icons.play_arrow_rounded),
                              label: const Text('Watch Training Video'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: orange,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                            ),
                          ),
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

class PartnerEmergencyPage extends StatelessWidget {
  const PartnerEmergencyPage({super.key});

  Future<void> _call(BuildContext context, String number, String label) async {
    final ok = await launchUrl(Uri(scheme: 'tel', path: number));
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$label call open नहीं हो सका.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Emergency / Help',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          const Text(
            'Emergency Contacts',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 8),
          const Text(
            'जरूरत पड़ने पर नीचे से तुरंत call करें.',
            style: TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 20),
          SizedBox(
            height: 70,
            child: FilledButton.icon(
              onPressed: () => _call(context, '108', 'Ambulance'),
              icon: const Icon(Icons.local_hospital_rounded, size: 30),
              label: const Text(
                'CALL AMBULANCE  •  108',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 70,
            child: FilledButton.icon(
              onPressed: () => _call(context, '112', 'Police / Emergency'),
              icon: const Icon(Icons.local_police_rounded, size: 30),
              label: const Text(
                'CALL POLICE / EMERGENCY  •  112',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: const [
                  Icon(Icons.security_rounded, color: orange),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Emergency buttons केवल phone dialer खोलते हैं।',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class PartnerSettingsPage extends StatefulWidget {
  const PartnerSettingsPage({super.key});

  @override
  State<PartnerSettingsPage> createState() => _PartnerSettingsPageState();
}

class _PartnerSettingsPageState extends State<PartnerSettingsPage> {
  bool notificationsEnabled = true;
  bool loading = true;
  bool savingNotifications = false;

  DocumentReference<Map<String, dynamic>> get partnerRef {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    return FirebaseFirestore.instance.collection('deliveryPartners').doc(uid);
  }

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final snap = await partnerRef.get();
      final data = snap.data() ?? {};
      if (!mounted) return;
      setState(() {
        notificationsEnabled = data['notificationsEnabled'] != false;
        loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => loading = false);
    }
  }

  Future<void> _setNotifications(bool value) async {
    setState(() => savingNotifications = true);
    try {
      await partnerRef.set({
        'notificationsEnabled': value,
        'settingsUpdatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      if (!mounted) return;
      setState(() {
        notificationsEnabled = value;
        savingNotifications = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            value
                ? 'Notifications ON कर दिया गया.'
                : 'Notifications OFF कर दिया गया.',
          ),
        ),
      );
    } on FirebaseException catch (e) {
      if (!mounted) return;
      setState(() => savingNotifications = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Setting save नहीं हुई: ${e.message ?? e.code}'),
        ),
      );
    }
  }

  Future<void> _syncNow() async {
    try {
      final partner = await partnerRef.get();
      final uid = FirebaseAuth.instance.currentUser!.uid;
      final orders = await FirebaseFirestore.instance
          .collection('orders')
          .where('deliveryPartnerId', isEqualTo: uid)
          .limit(1)
          .get();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Data sync complete • Profile: ${partner.exists ? 'OK' : 'Missing'} • Orders connection: OK',
          ),
        ),
      );
    } on FirebaseException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Data sync failed: ${e.message ?? e.code}')),
      );
    }
  }

  void _showSecurity() {
    final phone =
        FirebaseAuth.instance.currentUser?.phoneNumber ?? 'Not available';
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text(
          'Account Security',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
        content: Text(
          'Login mobile: $phone\n\n'
          'Your account uses Firebase Phone OTP authentication. '
          'For security, password is not stored in this app.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showAppInfo() {
    showAboutDialog(
      context: context,
      applicationName: 'FlashCart Delivery',
      applicationVersion: '1.0.0',
      applicationLegalese: 'Delivery Partner Application',
      applicationIcon: const CircleAvatar(
        backgroundColor: orange,
        child: Icon(Icons.delivery_dining_rounded, color: Colors.white),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Settings',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator(color: orange))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    children: [
                      const CircleAvatar(
                        radius: 27,
                        backgroundColor: Color(0xFFFFEEE8),
                        child: Icon(Icons.phone_android_rounded, color: orange),
                      ),
                      const SizedBox(width: 13),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Login Mobile',
                              style: TextStyle(color: Colors.grey),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              user?.phoneNumber ?? 'Not available',
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _SettingsActionTile(
                  icon: Icons.notifications_active_outlined,
                  title: 'Notifications',
                  subtitle: notificationsEnabled
                      ? 'New order and support alerts are ON'
                      : 'Notifications are OFF',
                  trailing: savingNotifications
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Switch(
                          value: notificationsEnabled,
                          onChanged: _setNotifications,
                          activeThumbColor: orange,
                        ),
                  onTap: savingNotifications
                      ? null
                      : () => _setNotifications(!notificationsEnabled),
                ),
                _SettingsActionTile(
                  icon: Icons.security_rounded,
                  title: 'Account Security',
                  subtitle: 'Phone OTP based secure login',
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: _showSecurity,
                ),
                _SettingsActionTile(
                  icon: Icons.cloud_done_outlined,
                  title: 'Data Sync',
                  subtitle: 'Refresh partner profile and assigned orders',
                  trailing: const Icon(Icons.sync_rounded),
                  onTap: _syncNow,
                ),
                _SettingsActionTile(
                  icon: Icons.directions_bike_rounded,
                  title: 'Vehicle Details',
                  subtitle: 'Vehicle, vehicle number and delivery area',
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => showEditPartnerDetails(context),
                ),
                _SettingsActionTile(
                  icon: Icons.info_outline_rounded,
                  title: 'FlashCart Delivery',
                  subtitle: 'App information and version',
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: _showAppInfo,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Changes are saved to your Delivery Partner profile.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
            ),
    );
  }
}

class _SettingsActionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _SettingsActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
      ),
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 4),
        leading: CircleAvatar(
          backgroundColor: const Color(0xFFF3F4F8),
          child: Icon(icon, color: dark),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
        subtitle: Text(subtitle),
        trailing: trailing,
      ),
    );
  }
}

void showReferral(BuildContext context) {
  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 8, 22, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircleAvatar(
              radius: 34,
              backgroundColor: Color(0xFFFFF0C2),
              child: Icon(Icons.card_giftcard_rounded, color: dark, size: 35),
            ),
            const SizedBox(height: 12),
            const Text(
              'Refer & Earn',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 5),
            const Text(
              'Refer your friends and earn up to ₹14,000 as per the applicable referral offer.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.pop(sheetContext);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Referral feature के लिए अपना referral system जोड़ें.',
                      ),
                    ),
                  );
                },
                icon: const Icon(Icons.share_rounded),
                label: const Text('Share Referral'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: orange,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(15),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

void showVehicle(BuildContext context) {
  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) {
      final maxHeight = MediaQuery.sizeOf(sheetContext).height * 0.72;
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Vehicle',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 5),
                const Text(
                  'Apna vehicle details update karein ya rental option dekhein.',
                  style: TextStyle(color: Colors.grey, fontSize: 14),
                ),
                const SizedBox(height: 15),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: orange,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(50),
                    ),
                    onPressed: () async {
                      Navigator.pop(sheetContext);
                      // Wait for the sheet route to finish closing before
                      // opening the next dialog. This avoids route/dependent
                      // lifecycle assertions on some Flutter versions.
                      await Future<void>.delayed(
                        const Duration(milliseconds: 180),
                      );
                      if (context.mounted) {
                        await showEditPartnerDetails(context);
                      }
                    },
                    icon: const Icon(Icons.edit_rounded),
                    label: const Text(
                      'Add / Edit Vehicle Details',
                      style: TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Rental Options',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 9),
                vehicleOption(
                  'Electric Scooter',
                  'From ₹250/day',
                  Icons.electric_scooter_rounded,
                  blue,
                ),
                vehicleOption(
                  'Petrol Scooter',
                  'Daily rental',
                  Icons.two_wheeler_rounded,
                  orange,
                ),
                const SizedBox(height: 2),
                const Text(
                  'Rental availability and price may vary by location.',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

Widget vehicleOption(
  String title,
  String subtitle,
  IconData icon,
  Color color,
) {
  return Container(
    margin: const EdgeInsets.only(bottom: 10),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(17),
      border: Border.all(color: const Color(0xFFE8E8EE)),
    ),
    child: Row(
      children: [
        CircleAvatar(
          backgroundColor: color.withValues(alpha: .10),
          child: Icon(icon, color: color),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
              Text(subtitle, style: const TextStyle(color: Colors.grey)),
            ],
          ),
        ),
        const Icon(Icons.arrow_forward_ios_rounded, size: 16),
      ],
    ),
  );
}

double calculateDeliveryEarning(Map<String, dynamic> order) {
  double orderValue = moneyFrom(
    order['totalAmount'] ??
        order['grandTotal'] ??
        order['orderTotal'] ??
        order['total'] ??
        order['amount'] ??
        order['subtotal'] ??
        0,
  );

  if (orderValue <= 0 && order['items'] is List) {
    for (final raw in (order['items'] as List)) {
      if (raw is Map) {
        final item = Map<String, dynamic>.from(raw);
        final quantity = moneyFrom(item['quantity'] ?? 1);
        final price = moneyFrom(item['price'] ?? item['unitPrice'] ?? 0);
        final itemTotal = moneyFrom(item['total'] ?? 0);
        orderValue += itemTotal > 0 ? itemTotal : price * quantity;
      }
    }
  }

  // Delivery partner earning slab:
  // ₹0–₹49 = ₹15
  // ₹50–₹99 = ₹17
  // ₹100–₹149 = ₹19
  // ₹150–₹199 = ₹20
  // ₹200–₹299 = ₹21
  // ₹300–₹399 = ₹23
  // ₹400–₹499 = ₹25
  // ₹500–₹699 = ₹27
  // ₹700–₹1000 = ₹29
  // ₹1001–₹1399 = ₹31
  // ₹1400+ = ₹35
  if (orderValue < 50) return 15.0;
  if (orderValue < 100) return 17.0;
  if (orderValue < 150) return 19.0;
  if (orderValue < 200) return 20.0;
  if (orderValue < 300) return 21.0;
  if (orderValue < 400) return 23.0;
  if (orderValue < 500) return 25.0;
  if (orderValue < 700) return 27.0;
  if (orderValue <= 1000) return 29.0;
  if (orderValue < 1400) return 31.0;
  return 35.0;
}

double moneyFrom(dynamic value) {
  if (value == null) return 0.0;

  if (value is num) {
    return value.toDouble();
  }

  if (value is String) {
    final cleaned = value.replaceAll(',', '').replaceAll('₹', '').trim();
    return double.tryParse(cleaned) ?? 0.0;
  }

  return 0.0;
}

DateTime? timestampFrom(dynamic value) {
  if (value is Timestamp) {
    return value.toDate();
  }

  if (value is DateTime) {
    return value;
  }

  return null;
}

String formatMoney(double value) {
  return value.toStringAsFixed(2);
}

bool sameDay(DateTime? a, DateTime b) {
  if (a == null) return false;
  return a.year == b.year && a.month == b.month && a.day == b.day;
}

class PartnerSupportPage extends StatefulWidget {
  const PartnerSupportPage({super.key});

  @override
  State<PartnerSupportPage> createState() => _PartnerSupportPageState();
}

class _PartnerSupportPageState extends State<PartnerSupportPage> {
  final subjectController = TextEditingController();
  final descriptionController = TextEditingController();
  final orderIdController = TextEditingController();

  String category = 'Order / Delivery';
  bool submitting = false;

  final categories = const [
    'Order / Delivery',
    'Customer Issue',
    'Payment / Earnings',
    'App / Login',
    'Vehicle',
    'Other',
  ];

  @override
  void dispose() {
    subjectController.dispose();
    descriptionController.dispose();
    orderIdController.dispose();
    super.dispose();
  }

  Future<void> submitComplaint() async {
    FocusScope.of(context).unfocus();

    final subject = subjectController.text.trim();
    final description = descriptionController.text.trim();
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      _message('Login session समाप्त हो गई है। फिर से login करें');
      return;
    }

    if (subject.length < 3) {
      _message('Complaint subject लिखें');
      return;
    }

    if (description.length < 10) {
      _message('Complaint का पूरा विवरण लिखें');
      return;
    }

    setState(() => submitting = true);

    try {
      final partner = await FirebaseFirestore.instance
          .collection('deliveryPartners')
          .doc(user.uid)
          .get();

      final data = partner.data() ?? <String, dynamic>{};

      await FirebaseFirestore.instance
          .collection('deliveryPartnerComplaints')
          .add({
            'partnerId': user.uid,
            'partnerName': data['name']?.toString() ?? 'Delivery Partner',
            'partnerPhone': data['phone']?.toString() ?? user.phoneNumber ?? '',
            'category': category,
            'subject': subject,
            'description': description,
            'orderId': orderIdController.text.trim(),
            'status': 'Pending',
            'createdAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
          });

      if (!mounted) return;

      subjectController.clear();
      descriptionController.clear();
      orderIdController.clear();

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Complaint successfully submitted'),
          backgroundColor: green,
          behavior: SnackBarBehavior.floating,
        ),
      );
      Navigator.pop(context);
    } on FirebaseException catch (e) {
      if (mounted) {
        _message('Complaint submit नहीं हुई: ${e.message ?? e.code}');
      }
    } catch (e) {
      if (mounted) {
        _message('Complaint submit नहीं हुई: $e');
      }
    } finally {
      if (mounted) setState(() => submitting = false);
    }
  }

  void _message(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(value),
        backgroundColor: red,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Support & Complaint',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [orange, orange2],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(23),
            ),
            child: const Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: Colors.white,
                  child: Icon(
                    Icons.support_agent_rounded,
                    color: orange,
                    size: 31,
                  ),
                ),
                SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Need Help?',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 21,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      SizedBox(height: 3),
                      Text(
                        'Send your issue to the FlashCart support team.',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          const Text(
            'Complaint Category',
            style: TextStyle(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: category,
            decoration: inputDecoration('Category', Icons.category_outlined),
            items: categories
                .map(
                  (item) =>
                      DropdownMenuItem<String>(value: item, child: Text(item)),
                )
                .toList(),
            onChanged: submitting
                ? null
                : (value) {
                    if (value != null) setState(() => category = value);
                  },
          ),
          const SizedBox(height: 14),
          TextField(
            controller: subjectController,
            enabled: !submitting,
            maxLength: 80,
            decoration: inputDecoration(
              'Complaint Subject',
              Icons.title_rounded,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: orderIdController,
            enabled: !submitting,
            decoration: inputDecoration(
              'Order ID (Optional)',
              Icons.receipt_long_outlined,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: descriptionController,
            enabled: !submitting,
            minLines: 5,
            maxLines: 8,
            maxLength: 1000,
            decoration: inputDecoration(
              'Describe your issue',
              Icons.description_outlined,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 54,
            child: ElevatedButton.icon(
              onPressed: submitting ? null : submitComplaint,
              icon: submitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.send_rounded),
              label: Text(
                submitting ? 'Submitting...' : 'Submit Complaint',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: orange,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(15),
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'My Recent Complaints',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 10),
          if (user != null)
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: FirebaseFirestore.instance
                  .collection('deliveryPartnerComplaints')
                  .where('partnerId', isEqualTo: user.uid)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return _supportErrorCard(
                    'Complaints load नहीं हुई',
                    '${snapshot.error}',
                  );
                }

                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: CircularProgressIndicator(color: orange),
                    ),
                  );
                }

                final docs = [...(snapshot.data?.docs ?? [])];
                docs.sort((a, b) {
                  final at =
                      timestampFrom(a.data()['createdAt'])
                          ?.millisecondsSinceEpoch ??
                      0;
                  final bt =
                      timestampFrom(b.data()['createdAt'])
                          ?.millisecondsSinceEpoch ??
                      0;
                  return bt.compareTo(at);
                });

                if (docs.isEmpty) {
                  return _supportEmptyCard();
                }

                return Column(
                  children: docs.take(10).map((doc) {
                    final data = doc.data();
                    final status = data['status']?.toString() ?? 'Pending';
                    final statusColor = status == 'Resolved'
                        ? green
                        : status == 'Rejected'
                        ? red
                        : orange;

                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(15),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Row(
                        children: [
                          CircleAvatar(
                            backgroundColor: statusColor.withValues(alpha: .10),
                            child: Icon(
                              status == 'Resolved'
                                  ? Icons.check_circle_outline_rounded
                                  : Icons.support_agent_rounded,
                              color: statusColor,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  data['subject']?.toString() ?? 'Complaint',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  data['category']?.toString() ?? '',
                                  style: const TextStyle(color: Colors.grey),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            status,
                            style: TextStyle(
                              color: statusColor,
                              fontWeight: FontWeight.w900,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _supportEmptyCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(19),
      ),
      child: const Column(
        children: [
          Icon(Icons.mark_email_read_outlined, size: 42, color: orange),
          SizedBox(height: 8),
          Text(
            'No complaints yet',
            style: TextStyle(fontWeight: FontWeight.w900),
          ),
          SizedBox(height: 3),
          Text(
            'Your submitted complaints will appear here.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _supportErrorCard(String title, String detail) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF2F2),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Text('$title\n$detail', style: const TextStyle(color: red)),
    );
  }
}

// ============================================================
// BANK DETAILS & DOCUMENTS — PARTNER SELF SERVICE
// ============================================================
class PartnerBankDetailsPage extends StatefulWidget {
  const PartnerBankDetailsPage({super.key});
  @override
  State<PartnerBankDetailsPage> createState() => _PartnerBankDetailsPageState();
}

class _PartnerBankDetailsPageState extends State<PartnerBankDetailsPage> {
  final _formKey = GlobalKey<FormState>();
  final _holder = TextEditingController();
  final _bank = TextEditingController();
  final _account = TextEditingController();
  final _confirm = TextEditingController();
  final _ifsc = TextEditingController();
  final _upi = TextEditingController();
  final _picker = ImagePicker();
  bool _loading = true, _saving = false, _uploading = false;
  bool _editingVerifiedBank = false;
  String _documentPath = '',
      _documentName = '',
      _verification = 'Not submitted';

  String get _uid => FirebaseAuth.instance.currentUser!.uid;
  DocumentReference<Map<String, dynamic>> get _ref =>
      FirebaseFirestore.instance.collection('deliveryPartners').doc(_uid);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final snap = await _ref.get();
      final d = snap.data() ?? {};
      final b = Map<String, dynamic>.from(
        d['payoutBank'] is Map ? d['payoutBank'] : {},
      );
      _holder.text = (b['accountHolderName'] ?? '').toString();
      _bank.text = (b['bankName'] ?? '').toString();
      _account.text = (b['accountNumber'] ?? '').toString();
      _confirm.text = _account.text;
      _ifsc.text = (b['ifsc'] ?? '').toString();
      _upi.text = (b['upiId'] ?? '').toString();
      _documentPath = (b['documentPath'] ?? '').toString();
      _documentName = (b['documentName'] ?? '').toString();
      _verification = (b['verificationStatus'] ?? 'Not submitted').toString();
    } catch (e) {
      _notice('Bank details load नहीं हो सके: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _uploadDocument() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _notice('पहले login करें।');
      return;
    }
    final x = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 82,
      maxWidth: 1800,
    );
    if (x == null) return;

    setState(() => _uploading = true);
    try {
      final bytes = await x.readAsBytes();
      if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) {
        throw Exception('Image 8 MB से छोटी होनी चाहिए।');
      }
      final lowerName = x.name.toLowerCase();
      final contentType = lowerName.endsWith('.png')
          ? 'image/png'
          : lowerName.endsWith('.webp')
          ? 'image/webp'
          : 'image/jpeg';
      final token = await user.getIdToken(true);
      if (token == null) throw Exception('Firebase login token नहीं मिला।');

      // Public configuration only. Never place a Supabase secret/service key here.
      const supabaseUrl = String.fromEnvironment(
        'SUPABASE_URL',
        defaultValue: 'https://dwygvqudcozuqtesyrtb.supabase.co',
      );
      const supabasePublishableKey = String.fromEnvironment(
        'SUPABASE_PUBLISHABLE_KEY',
      );
      if (supabaseUrl.isEmpty || supabasePublishableKey.isEmpty) {
        throw Exception(
          'SUPABASE_URL और SUPABASE_PUBLISHABLE_KEY build configuration में सेट करें।',
        );
      }

      final response = await http.post(
        Uri.parse('$supabaseUrl/functions/v1/partner-bank-upload'),
        headers: {
          'apikey': supabasePublishableKey,
          'Authorization': 'Bearer $token',
          'Content-Type': contentType,
        },
        body: bytes,
      );
      final result = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode != 200 || result['path'] == null) {
        throw Exception(result['error'] ?? 'Upload failed');
      }
      if (!mounted) return;
      setState(() {
        _documentPath = result['path'].toString();
        _documentName = x.name;
      });
      _notice('Document upload हो गया। अब Save Details दबाएँ।');
    } catch (e) {
      _notice('Document upload नहीं हुआ: $e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_account.text.trim() != _confirm.text.trim()) {
      _notice('दोनों account number एक जैसे होने चाहिए।');
      return;
    }
    if (_documentPath.isEmpty) {
      _notice('Cancelled cheque या passbook की image upload करें।');
      return;
    }
    setState(() => _saving = true);
    try {
      await _ref.set({
        'payoutBank': {
          'accountHolderName': _holder.text.trim(),
          'bankName': _bank.text.trim(),
          'accountNumber': _account.text.trim(),
          'ifsc': _ifsc.text.trim().toUpperCase(),
          'upiId': _upi.text.trim(),
          'documentPath': _documentPath,
          'documentName': _documentName,
          'verificationStatus': 'Pending',
          'verified': false,
          'submittedAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        },
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      if (mounted) {
        setState(() {
          _verification = 'Pending';
          _editingVerifiedBank = false;
        });
        _notice('Bank details CEO verification के लिए भेज दी गई हैं।');
      }
    } catch (e) {
      _notice('Save नहीं हुआ: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _notice(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  void dispose() {
    _holder.dispose();
    _bank.dispose();
    _account.dispose();
    _confirm.dispose();
    _ifsc.dispose();
    _upi.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading)
      return const Center(child: CircularProgressIndicator(color: orange));
    final verified = _verification.toLowerCase() == 'verified';
    final bankFieldsLocked = verified && !_editingVerifiedBank;
    return Container(
      color: bg,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [orange, orange2]),
              borderRadius: BorderRadius.circular(24),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.account_balance_rounded,
                  color: Colors.white,
                  size: 34,
                ),
                SizedBox(height: 10),
                Text(
                  'Bank & Payout Details',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 23,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                SizedBox(height: 5),
                Text(
                  'सही details भरें ताकि payment आपके सही account में भेजा जा सके।',
                  style: TextStyle(color: Colors.white),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(
                    verified
                        ? Icons.verified_rounded
                        : Icons.pending_actions_rounded,
                    color: verified ? green : orange,
                    size: 30,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'CEO verification status',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                        Text(
                          _verification,
                          style: TextStyle(
                            color: verified ? green : orange,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Account information',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _holder,
                      readOnly: bankFieldsLocked,
                      decoration: inputDecoration(
                        'Account holder name',
                        Icons.person_outline,
                      ),
                      validator: (v) =>
                          (v ?? '').trim().isEmpty ? 'नाम भरें' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _bank,
                      readOnly: bankFieldsLocked,
                      decoration: inputDecoration(
                        'Bank name',
                        Icons.account_balance_outlined,
                      ),
                      validator: (v) =>
                          (v ?? '').trim().isEmpty ? 'Bank name भरें' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _account,
                      readOnly: bankFieldsLocked,
                      keyboardType: TextInputType.number,
                      obscureText: true,
                      decoration: inputDecoration(
                        'Bank account number',
                        Icons.lock_outline,
                      ),
                      validator: (v) => (v ?? '').trim().length < 6
                          ? 'Account number जाँचें'
                          : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _confirm,
                      readOnly: bankFieldsLocked,
                      keyboardType: TextInputType.number,
                      decoration: inputDecoration(
                        'Confirm account number',
                        Icons.verified_user_outlined,
                      ),
                      validator: (v) => (v ?? '').trim().isEmpty
                          ? 'Account number दोबारा भरें'
                          : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _ifsc,
                      readOnly: bankFieldsLocked,
                      textCapitalization: TextCapitalization.characters,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                          RegExp(r'[A-Za-z0-9]'),
                        ),
                        LengthLimitingTextInputFormatter(11),
                      ],
                      decoration: inputDecoration('IFSC code', Icons.code),
                      validator: (v) =>
                          !RegExp(r'^[A-Za-z]{4}0[A-Za-z0-9]{6}$')
                              .hasMatch((v ?? '').trim())
                          ? 'Valid IFSC भरें'
                          : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _upi,
                      readOnly: bankFieldsLocked,
                      decoration: inputDecoration(
                        'UPI ID (optional)',
                        Icons.qr_code_2,
                      ),
                      validator: (v) {
                        final x = (v ?? '').trim();
                        return x.isNotEmpty && !x.contains('@')
                            ? 'UPI ID जाँचें'
                            : null;
                      },
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: bg,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.description_outlined,
                            size: 30,
                            color: orange,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _documentName.isEmpty
                                  ? 'Cancelled cheque / passbook image आवश्यक है'
                                  : 'Uploaded: $_documentName',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: (_uploading || bankFieldsLocked)
                                ? null
                                : _uploadDocument,
                            icon: _uploading
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.upload_file),
                            label: const Text('Upload'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    if (bankFieldsLocked) ...[
                      FilledButton.icon(
                        onPressed: _saving
                            ? null
                            : () => setState(() => _editingVerifiedBank = true),
                        style: FilledButton.styleFrom(
                          backgroundColor: orange,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        icon: const Icon(Icons.edit_rounded),
                        label: const Text('Edit Bank Details'),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Verified bank details read-only हैं। बदलाव करने के लिए Edit Bank Details दबाएँ। Update करने पर CEO verification दोबारा Pending हो जाएगी।',
                        style: TextStyle(
                          color: Color(0xFF808080),
                          fontSize: 12,
                        ),
                      ),
                    ] else ...[
                      FilledButton.icon(
                        onPressed: _saving ? null : _save,
                        style: FilledButton.styleFrom(
                          backgroundColor: orange,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        icon: _saving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.save_rounded),
                        label: Text(
                          _saving
                              ? 'Saving…'
                              : (verified && _editingVerifiedBank)
                              ? 'Update Details & Send for CEO Re-verification'
                              : 'Save Details & Send for Verification',
                        ),
                      ),
                      if (verified && _editingVerifiedBank) ...[
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: _saving
                              ? null
                              : () async {
                                  setState(() => _editingVerifiedBank = false);
                                  await _load();
                                },
                          icon: const Icon(Icons.close_rounded),
                          label: const Text('Cancel Editing'),
                        ),
                      ],
                    ],
                    const SizedBox(height: 8),
                    const Text(
                      'Security: bank details केवल अपने login से submit करें। Approval केवल CEO कर सकता है।',
                      style: const TextStyle(
                        color: Color(0xFF808080),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
