import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;

import 'firebase_options.dart';

const flashCartSupportEmail = 'sudhirkuumar553@gmail.com';

// यहाँ पेस्ट करें:
final List<String> orderStatuses = [
  'Pending',
  'Order Confirmed',
  'Preparing',
  'Shipped',
  'Out for Delivery',
  'Delivered',
  'Cancelled',
];

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  runApp(const FlashCartAdminApp());
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

String adminIncentiveDateKey([DateTime? value]) {
  final d = value ?? DateTime.now();
  return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

double adminMoney(dynamic value) {
  if (value is num) return value.toDouble();
  if (value is String) {
    return double.tryParse(
          value.replaceAll(',', '').replaceAll('₹', '').trim(),
        ) ??
        0;
  }
  return 0;
}

double adminIncentiveTargetTotal(dynamic targets, int count) {
  if (targets is! List) return 0;
  double best = 0;
  for (final raw in targets) {
    if (raw is! Map) continue;
    final target = raw['orderCount'] is num
        ? (raw['orderCount'] as num).toInt()
        : int.tryParse(raw['orderCount']?.toString() ?? '') ?? 0;
    final amount = adminMoney(raw['amount']);
    if (target > 0 && count >= target && amount > best) best = amount;
  }
  return best;
}

Future<double> applyAdminDeliveryIncentive({
  required FirebaseFirestore db,
  required String partnerId,
  required Transaction transaction,
  required Map<String, dynamic> partnerData,
  required int nextDeliveredToday,
}) async {
  final dateKey = adminIncentiveDateKey();
  final planRef = db.collection('incentivePlans').doc(dateKey);
  final planSnap = await transaction.get(planRef);
  final plan = planSnap.data() ?? <String, dynamic>{};
  final storedDate = partnerData['incentiveDate']?.toString() ?? '';
  final paid = storedDate == dateKey
      ? adminMoney(partnerData['incentivePaidToday'])
      : 0;
  final targetTotal = adminIncentiveTargetTotal(
    plan['targets'],
    nextDeliveredToday,
  );
  final delta = targetTotal > paid ? targetTotal - paid : 0.0;
  return delta;
}

// ============================================================
// APP
// ============================================================

class FlashCartAdminApp extends StatelessWidget {
  const FlashCartAdminApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'FlashCart Admin',
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'Arial',
        scaffoldBackgroundColor: const Color(0xFFF6F7FB),
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFFF6B35)),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: Color(0xFF171717),
          elevation: 0,
        ),
      ),
      home: const AdminLoginPage(),
    );
  }
}

// ============================================================
// COLORS
// ============================================================

const orange = Color(0xFFFF6B35);
const dark = Color(0xFF171717);
const grey = Color(0xFF707070);
const lightOrange = Color(0xFFFFF0E9);
const green = Color(0xFF188A42);
const red = Color(0xFFE53935);
const yellow = Color(0xFFFFB300);

// Current signed-in store scope. Set at login from admins/{uid} or its branch record.
String currentAdminBranchId = '';
String currentAdminBranchName = '';

// ============================================================
// ADMIN LOGIN
// ============================================================

class AdminLoginPage extends StatefulWidget {
  const AdminLoginPage({super.key});

  @override
  State<AdminLoginPage> createState() => _AdminLoginPageState();
}

class _AdminLoginPageState extends State<AdminLoginPage> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();

  bool loading = false;
  bool hidePassword = true;

  Future<void> login() async {
    final email = emailController.text.trim();
    final password = passwordController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      message('Email और Password भरें');
      return;
    }

    setState(() => loading = true);

    try {
      final credential = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      final uid = credential.user!.uid;

      final db = FirebaseFirestore.instance;
      final adminRef = db.collection('admins').doc(uid);
      final adminDoc = await adminRef.get();
      final managerDoc = await db.collection('managers').doc(uid).get();

      // CEO registration writes both admins/{uid} and managers/{uid}.
      // Older/partially-created profiles may have the branch only in managers/{uid}.
      final adminData = adminDoc.data() ?? <String, dynamic>{};
      final managerData = managerDoc.data() ?? <String, dynamic>{};

      if (!adminDoc.exists && !managerDoc.exists) {
        await FirebaseAuth.instance.signOut();
        message(
          'यह account Admin/Manager के रूप में authorized नहीं है। CEO App में account registration जाँचें।',
        );
        return;
      }

      var branchId =
          (adminData['branchId'] ??
                  adminData['storeId'] ??
                  managerData['branchId'] ??
                  managerData['storeId'] ??
                  '')
              .toString()
              .trim();
      var branchName =
          (adminData['branchName'] ??
                  adminData['storeName'] ??
                  managerData['branchName'] ??
                  managerData['storeName'] ??
                  '')
              .toString()
              .trim();

      // If the profile has no branch ID, try to resolve it from branches.
      if (branchId.isEmpty) {
        final branchSnap = await db
            .collection('branches')
            .where('managerUid', isEqualTo: uid)
            .limit(2)
            .get();
        if (branchSnap.docs.length == 1) {
          final branch = branchSnap.docs.first;
          branchId = branch.id;
          final branchData = branch.data();
          branchName =
              (branchData['branchName'] ??
                      branchData['storeName'] ??
                      branchName)
                  .toString()
                  .trim();
        }
      }

      if (branchId.isNotEmpty) {
        // Keep both profiles consistent for future logins.
        final profileUpdate = <String, dynamic>{
          'uid': uid,
          'email': credential.user?.email?.trim().toLowerCase() ?? '',
          'branchId': branchId,
          'storeId': branchId,
          'branchName': branchName,
          'storeName': branchName,
          'updatedAt': FieldValue.serverTimestamp(),
        };
        await adminRef.set({
          ...profileUpdate,
          'role': adminData['role'] ?? 'admin',
          'active': adminData['active'] ?? managerData['active'] ?? true,
        }, SetOptions(merge: true));
      }
      if (branchId.isEmpty) {
        await FirebaseAuth.instance.signOut();
        message(
          'Branch ID नहीं मिली। CEO App में इस UID के admins और managers रिकॉर्ड में branchId जाँचें, और branches में managerUid सही रखें।',
        );
        return;
      }
      currentAdminBranchId = branchId;
      currentAdminBranchName = branchName;

      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const AdminDashboardPage()),
      );
    } on FirebaseAuthException catch (e) {
      String text = 'Login failed';

      if (e.code == 'invalid-credential') {
        text = 'Email या Password गलत है';
      } else if (e.code == 'user-not-found') {
        text = 'Admin account नहीं मिला';
      } else if (e.code == 'wrong-password') {
        text = 'Password गलत है';
      } else if (e.code == 'invalid-email') {
        text = 'Email सही नहीं है';
      }

      message(text);
    } catch (e) {
      message('कुछ समस्या हुई। फिर से कोशिश करें।');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> forgotPassword() async {
    final email = emailController.text.trim();
    if (email.isEmpty) {
      message('पहले Admin Email दर्ज करें');
      return;
    }
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)) {
      message('Valid email address दर्ज करें');
      return;
    }
    setState(() => loading = true);
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
      if (!mounted) return;
      message(
        'Password reset link इस email पर भेज दिया गया है। Inbox और Spam folder जाँचें।',
      );
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      switch (e.code) {
        case 'invalid-email':
          message('Email address सही नहीं है');
          break;
        case 'user-not-found':
          message('इस email से Firebase Authentication account नहीं मिला');
          break;
        case 'too-many-requests':
          message('बहुत ज्यादा प्रयास हुए हैं। कुछ देर बाद कोशिश करें');
          break;
        case 'operation-not-allowed':
          message(
            'Firebase Console में Email/Password Authentication enable करें',
          );
          break;
        default:
          message('Reset email नहीं भेजा जा सका: ${e.message ?? e.code}');
      }
    } catch (e) {
      if (mounted) message('Password reset में समस्या हुई: $e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void message(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
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
            colors: [Color(0xFFFF6B35), Color(0xFFFF9F43), Color(0xFFF6F7FB)],
            stops: [0, .38, .38],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(22),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 460),
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(30),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(.12),
                      blurRadius: 30,
                      offset: const Offset(0, 15),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    Container(
                      width: 88,
                      height: 88,
                      decoration: BoxDecoration(
                        color: orange,
                        borderRadius: BorderRadius.circular(25),
                      ),
                      child: const Icon(
                        Icons.shopping_cart_rounded,
                        color: Colors.white,
                        size: 48,
                      ),
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      'FlashCart',
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const Text(
                      'ADMIN PANEL',
                      style: TextStyle(
                        color: orange,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 2,
                      ),
                    ),
                    const SizedBox(height: 35),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Welcome back 👋',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(height: 5),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Login करके अपने FlashCart store को manage करें',
                        style: TextStyle(color: grey),
                      ),
                    ),
                    const SizedBox(height: 25),
                    TextField(
                      controller: emailController,
                      keyboardType: TextInputType.emailAddress,
                      decoration: inputDecoration(
                        'Admin Email',
                        Icons.email_outlined,
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: passwordController,
                      obscureText: hidePassword,
                      decoration: inputDecoration(
                        'Password',
                        Icons.lock_outline,
                        suffix: IconButton(
                          onPressed: () {
                            setState(() {
                              hidePassword = !hidePassword;
                            });
                          },
                          icon: Icon(
                            hidePassword
                                ? Icons.visibility_off
                                : Icons.visibility,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 25),
                    SizedBox(
                      width: double.infinity,
                      height: 55,
                      child: ElevatedButton(
                        onPressed: loading ? null : login,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: orange,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: loading
                            ? const CircularProgressIndicator(
                                color: Colors.white,
                              )
                            : const Text(
                                'LOGIN TO ADMIN',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: loading ? null : forgotPassword,
                        icon: const Icon(Icons.lock_reset_rounded),
                        label: const Text('Forgot Password?'),
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

// ============================================================
// DASHBOARD
// ============================================================

class AdminDashboardPage extends StatefulWidget {
  const AdminDashboardPage({super.key});

  @override
  State<AdminDashboardPage> createState() => _AdminDashboardPageState();
}

class _AdminDashboardPageState extends State<AdminDashboardPage> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  int selectedIndex = 0;

  int get _bottomNavIndex {
    switch (selectedIndex) {
      case 0:
        return 0;
      case 2:
        return 1;
      case 1:
        return 2;
      case 11:
        return 3;
      default:
        return 4;
    }
  }

  void _onBottomNavTap(int index) {
    switch (index) {
      case 0:
        setState(() => selectedIndex = 0);
        break;
      case 1:
        setState(() => selectedIndex = 2);
        break;
      case 2:
        setState(() => selectedIndex = 1);
        break;
      case 3:
        setState(() => selectedIndex = 11);
        break;
      case 4:
        _scaffoldKey.currentState?.openDrawer();
        break;
    }
  }

  final pages = [
    DashboardHome(),
    ProductsPage(),
    OrdersPage(),
    CategoriesPage(),
    CustomersPage(),
    DeliveryPartnersPage(),
    ComplaintsPage(),
    DeliveryPartnerComplaintsPage(),
    DeliveryAssetsAdminPage(),
    TrainingVideosAdminPage(),
    EmergencyCenterPage(),
    ReportsAnalyticsPage(),
    AdminNotificationsPage(),
    OffersCouponsPage(),
    DeliveryIncentivesPage(),
    AdminSettingsPage(),
    AdminWeeklyEarningsPage(),
    AdminProfilePage(),
    AdminPartnerPayoutPage(),
    AdminBankDetailsPage(
      branchId: currentAdminBranchId,
      branchName: currentAdminBranchName,
    ),
    AdminFestivalPostersPage(),
  ];

  final titles = [
    'Dashboard',
    'Products',
    'Orders',
    'Categories',
    'Customers',
    'Delivery Partners',
    'Customer Complaints',
    'Delivery Partner Complaints',
    'Delivery Assets',
    'Training Videos',
    'Emergency Center',
    'Reports & Analytics',
    'Notifications',
    'Offers & Coupons',
    'Delivery Incentives',
    'App Settings',
    'Weekly Earnings & Payout',
    'My Profile',
    'Partner Payments',
    'My Bank Details',
    'Festival Posters & Banners',
  ];

  StreamSubscription<QuerySnapshot>? _orderSubscription;
  bool _ordersListenerReady = false;

  @override
  void initState() {
    super.initState();
    _startNewOrderSound();
  }

  void _startNewOrderSound() {
    _orderSubscription = FirebaseFirestore.instance
        .collection('orders')
        .where('branchId', isEqualTo: currentAdminBranchId)
        .snapshots()
        .listen((snapshot) async {
          // First snapshot contains existing orders. No sound for old orders.
          if (!_ordersListenerReady) {
            _ordersListenerReady = true;
            return;
          }

          final hasNewOrder = snapshot.docChanges.any(
            (change) => change.type == DocumentChangeType.added,
          );

          if (!hasNewOrder) return;

          // Automatically assign every new order to the oldest eligible
          // online/available delivery partner before showing the alert.
          try {
            await AdminAutomation.autoAssignUnassignedOrders();
          } catch (_) {
            // Assignment errors must not stop the admin order alert.
          }

          // Phone's built-in alert sound. No extra package/asset required.
          await SystemSound.play(SystemSoundType.alert);

          if (!mounted) return;

          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('🔔 नया order आया है!'),
              behavior: SnackBarBehavior.floating,
              duration: Duration(seconds: 3),
            ),
          );
        });
  }

  Future<void> logout() async {
    await FirebaseAuth.instance.signOut();

    if (!mounted) return;

    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const AdminLoginPage()),
      (_) => false,
    );
  }

  @override
  void dispose() {
    _orderSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        title: Text(
          titles[selectedIndex],
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          IconButton(
            tooltip: 'Logout',
            onPressed: logout,
            icon: const Icon(Icons.logout_rounded),
          ),
          const SizedBox(width: 8),
        ],
      ),
      drawer: _drawer(),
      body: pages[selectedIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _bottomNavIndex,
        type: BottomNavigationBarType.fixed,
        selectedItemColor: orange,
        unselectedItemColor: grey,
        showUnselectedLabels: true,
        onTap: (index) {
          if (index == 4) {
            _scaffoldKey.currentState?.openDrawer();
          } else {
            _onBottomNavTap(index);
          }
        },
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.home_rounded),
            label: 'Home',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.shopping_bag_rounded),
            label: 'Orders',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.inventory_2_rounded),
            label: 'Products',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.analytics_rounded),
            label: 'Reports',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.apps_rounded),
            label: 'More',
          ),
        ],
      ),
    );
  }

  Widget _drawer() {
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [orange, Color(0xFFFF9F43)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(17),
                    ),
                    child: const Icon(
                      Icons.shopping_cart_rounded,
                      color: orange,
                      size: 32,
                    ),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'FlashCart',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 23,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Admin Management',
                          style: TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  _drawerSection('MAIN'),
                  drawerItem(0, Icons.dashboard_rounded, 'Dashboard'),
                  drawerItem(1, Icons.inventory_2_rounded, 'Products'),
                  drawerItem(2, Icons.shopping_bag_rounded, 'Orders'),
                  drawerItem(3, Icons.category_rounded, 'Categories'),
                  drawerItem(4, Icons.people_rounded, 'Customers'),
                  _drawerSection('DELIVERY'),
                  drawerItem(
                    5,
                    Icons.delivery_dining_rounded,
                    'Delivery Partners',
                  ),
                  drawerItem(8, Icons.inventory_2_rounded, 'Delivery Assets'),
                  drawerItem(
                    7,
                    Icons.support_agent_rounded,
                    'Partner Complaints',
                  ),
                  _drawerSection('CUSTOMER & SUPPORT'),
                  drawerItem(
                    6,
                    Icons.support_agent_rounded,
                    'Customer Complaints',
                  ),
                  drawerItem(10, Icons.emergency_rounded, 'Emergency Center'),
                  drawerItem(
                    9,
                    Icons.ondemand_video_rounded,
                    'Training Videos',
                  ),
                  _drawerSection('BUSINESS'),
                  drawerItem(
                    11,
                    Icons.analytics_rounded,
                    'Reports & Analytics',
                  ),
                  drawerItem(
                    12,
                    Icons.notifications_active_rounded,
                    'Notifications',
                  ),
                  drawerItem(13, Icons.local_offer_rounded, 'Offers & Coupons'),
                  drawerItem(
                    20,
                    Icons.campaign_rounded,
                    'Festival Posters & Banners',
                  ),
                  drawerItem(15, Icons.settings_rounded, 'App Settings'),
                  drawerItem(
                    16,
                    Icons.account_balance_wallet_rounded,
                    'Weekly Earnings & Payout',
                  ),
                  drawerItem(17, Icons.person_rounded, 'My Profile'),
                  drawerItem(18, Icons.payments_rounded, 'Partner Payments'),
                  drawerItem(
                    19,
                    Icons.account_balance_rounded,
                    'My Bank Details',
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              onTap: logout,
              leading: const Icon(Icons.logout_rounded, color: Colors.red),
              title: const Text(
                'Logout',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }

  Widget _drawerSection(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w900,
          color: grey,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget drawerItem(int index, IconData icon, String title) {
    final active = selectedIndex == index;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      decoration: BoxDecoration(
        color: active ? lightOrange : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
      ),
      child: ListTile(
        onTap: () {
          setState(() => selectedIndex = index);
          Navigator.pop(context);
        },
        leading: Icon(icon, color: active ? orange : grey),
        title: Text(
          title,
          style: TextStyle(
            fontWeight: active ? FontWeight.bold : FontWeight.normal,
            color: active ? orange : dark,
          ),
        ),
      ),
    );
  }
}

// ============================================================
// DASHBOARD HOME
// ============================================================

class DashboardHome extends StatelessWidget {
  const DashboardHome({super.key});

  Stream<int> count(String collection) {
    Query<Map<String, dynamic>> query = FirebaseFirestore.instance.collection(
      collection,
    );
    if (collection == 'orders') {
      query = query.where('branchId', isEqualTo: currentAdminBranchId);
    }
    return query.snapshots().map((snapshot) => snapshot.docs.length);
  }

  // Total sales from all orders. Supports the common total field names so
  // the dashboard keeps working with existing order documents.
  Stream<double> totalSales() {
    return FirebaseFirestore.instance
        .collection('orders')
        .where('branchId', isEqualTo: currentAdminBranchId)
        .snapshots()
        .map((snapshot) {
          double total = 0;

          for (final doc in snapshot.docs) {
            final data = doc.data();

            // Sales are counted after the order is delivered.
            final status = (data['status'] ?? '').toString().toLowerCase();
            if (status != 'delivered') continue;

            total += _extractOrderTotal(data);
          }

          return total;
        });
  }

  double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();

    if (value is String) {
      final cleaned = value.replaceAll(RegExp(r'[^0-9.\-]'), '');
      return double.tryParse(cleaned) ?? 0;
    }

    return 0;
  }

  double _extractOrderTotal(Map<String, dynamic> data) {
    // Common total field names used by the customer app/order document.
    const directKeys = [
      'total',
      'totalAmount',
      'total_amount',
      'grandTotal',
      'grand_total',
      'orderTotal',
      'order_total',
      'totalPrice',
      'total_price',
      'finalTotal',
      'final_total',
      'payableAmount',
      'payable_amount',
      'amount',
    ];

    for (final key in directKeys) {
      if (data.containsKey(key)) {
        final value = _toDouble(data[key]);
        if (value > 0) return value;
      }
    }

    // Some order schemas keep the final amount inside a summary/price map.
    const mapKeys = ['summary', 'priceDetails', 'price_details', 'pricing'];
    for (final mapKey in mapKeys) {
      final value = data[mapKey];
      if (value is Map) {
        for (final key in directKeys) {
          if (value.containsKey(key)) {
            final amount = _toDouble(value[key]);
            if (amount > 0) return amount;
          }
        }
      }
    }

    // Last fallback: calculate from items, including common quantity/price names.
    final items = data['items'] ?? data['orderItems'] ?? data['products'];
    if (items is List) {
      double itemTotal = 0;

      for (final item in items) {
        if (item is! Map) continue;

        final price = _toDouble(
          item['sellingPrice'] ??
              item['price'] ??
              item['unitPrice'] ??
              item['salePrice'] ??
              0,
        );

        final quantity = _toDouble(
          item['quantity'] ?? item['qty'] ?? item['count'] ?? 1,
        );

        itemTotal += price * (quantity <= 0 ? 1 : quantity);
      }

      // Add common delivery/extra charges if they exist.
      itemTotal += _toDouble(
        data['deliveryFee'] ??
            data['deliveryCharge'] ??
            data['delivery_charge'] ??
            0,
      );

      itemTotal += _toDouble(
        data['tax'] ?? data['gst'] ?? data['taxAmount'] ?? 0,
      );

      itemTotal -= _toDouble(
        data['discountAmount'] ?? data['discount_amount'] ?? 0,
      );

      if (itemTotal > 0) return itemTotal;
    }

    return 0;
  }

  String formatSales(double amount) {
    if (amount == amount.roundToDouble()) {
      return '₹${amount.toInt()}';
    }
    return '₹${amount.toStringAsFixed(2)}';
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async {},
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Good day, Admin 👋',
              style: TextStyle(fontSize: 27, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 5),
            const Text(
              'अपने FlashCart store की पूरी जानकारी यहाँ देखें।',
              style: TextStyle(color: grey),
            ),
            const SizedBox(height: 22),
            StreamBuilder<int>(
              stream: count('products'),
              builder: (_, snapshot) {
                return dashboardCard(
                  'Products',
                  '${snapshot.data ?? 0}',
                  Icons.inventory_2_rounded,
                );
              },
            ),
            const SizedBox(height: 12),
            StreamBuilder<int>(
              stream: count('orders'),
              builder: (_, snapshot) {
                return dashboardCard(
                  'Orders',
                  '${snapshot.data ?? 0}',
                  Icons.shopping_bag_rounded,
                );
              },
            ),
            const SizedBox(height: 12),
            StreamBuilder<double>(
              stream: totalSales(),
              builder: (_, snapshot) {
                return dashboardCard(
                  'Total Sales',
                  formatSales(snapshot.data ?? 0),
                  Icons.currency_rupee_rounded,
                );
              },
            ),
            const SizedBox(height: 12),
            StreamBuilder<int>(
              stream: count('users'),
              builder: (_, snapshot) {
                return dashboardCard(
                  'Customers',
                  '${snapshot.data ?? 0}',
                  Icons.people_rounded,
                );
              },
            ),
            const SizedBox(height: 12),
            StreamBuilder<int>(
              stream: count('categories'),
              builder: (_, snapshot) {
                return dashboardCard(
                  'Categories',
                  '${snapshot.data ?? 0}',
                  Icons.category_rounded,
                );
              },
            ),
            const SizedBox(height: 25),
            const Text(
              'Quick Actions',
              style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: quickButton(
                    context,
                    Icons.add_box_rounded,
                    'Add Product',
                    () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const AddProductPage(),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: quickButton(
                    context,
                    Icons.category_rounded,
                    'Categories',
                    () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const CategoriesPage(),
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
    );
  }

  Widget dashboardCard(String title, String value, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(.035), blurRadius: 15),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 55,
            height: 55,
            decoration: BoxDecoration(
              color: lightOrange,
              borderRadius: BorderRadius.circular(17),
            ),
            child: const Icon(Icons.analytics_rounded, color: orange),
          ),
          const SizedBox(width: 15),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
            ),
          ),
          Text(
            value,
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900),
          ),
        ],
      ),
    );
  }

  Widget quickButton(
    BuildContext context,
    IconData icon,
    String title,
    VoidCallback action,
  ) {
    return InkWell(
      onTap: action,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: orange,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          children: [
            Icon(icon, color: Colors.white, size: 30),
            const SizedBox(height: 8),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// PRODUCTS PAGE
// ============================================================

class ProductsPage extends StatefulWidget {
  const ProductsPage({super.key});

  @override
  State<ProductsPage> createState() => _ProductsPageState();
}

class _ProductsPageState extends State<ProductsPage> {
  String search = '';

  Future<void> deleteProduct(String id, String? imageUrl) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Product?'),
        content: const Text('क्या आप इस product को delete करना चाहते हैं?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      final productRef = FirebaseFirestore.instance
          .collection('products')
          .doc(id);
      final productSnap = await productRef.get();
      final productData = productSnap.data() ?? <String, dynamic>{};
      final productBranch = (productData['branchId'] ?? '').toString();
      if (!productSnap.exists || productBranch != currentAdminBranchId) {
        throw Exception('यह Product आपकी Branch का नहीं है।');
      }
      await productRef.delete();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Product deleted successfully')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Product delete नहीं हुआ')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: orange,
        foregroundColor: Colors.white,
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const AddProductPage()),
          );
        },
        icon: const Icon(Icons.add),
        label: const Text('Add Product'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
            child: TextField(
              onChanged: (value) {
                setState(() => search = value.toLowerCase());
              },
              decoration: InputDecoration(
                hintText: 'Search products...',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('products')
                  .where('branchId', isEqualTo: currentAdminBranchId)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(color: orange),
                  );
                }

                if (snapshot.hasError) {
                  return const Center(
                    child: Text('Products load करने में समस्या हुई'),
                  );
                }

                final docs = snapshot.data?.docs ?? [];

                final filtered = docs.where((doc) {
                  final data = doc.data() as Map<String, dynamic>;

                  final name = (data['name'] ?? '').toString().toLowerCase();

                  return name.contains(search);
                }).toList();

                if (filtered.isEmpty) {
                  return const Center(
                    child: Text(
                      'अभी कोई product नहीं है.\n+ Add Product से शुरू करें।',
                      textAlign: TextAlign.center,
                    ),
                  );
                }

                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 5, 16, 100),
                  itemCount: filtered.length,
                  itemBuilder: (_, index) {
                    final doc = filtered[index];
                    final data = doc.data() as Map<String, dynamic>;

                    return productCard(doc.id, data);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget productCard(String id, Map<String, dynamic> data) {
    final image = data['imageUrl']?.toString() ?? '';
    final name = data['name']?.toString() ?? 'Product';
    final selling = data['sellingPrice'] ?? 0;
    final original = data['originalPrice'] ?? 0;
    final discount = data['discount'] ?? 0;
    final unit = data['unit']?.toString() ?? '';
    final stock = data['stock'] ?? 0;
    final available = data['available'] ?? true;
    final description = data['description']?.toString().trim() ?? '';
    final deliveryMinutes = data['deliveryTimeMins'] ?? 10;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Container(
            width: 82,
            height: 82,
            decoration: BoxDecoration(
              color: const Color(0xFFF3F3F3),
              borderRadius: BorderRadius.circular(16),
            ),
            child: image.isEmpty
                ? const Icon(Icons.image_outlined, color: Colors.grey, size: 35)
                : ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Image.network(
                      image,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) {
                        return const Icon(Icons.broken_image_outlined);
                      },
                    ),
                  ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 5),
                Row(
                  children: [
                    Text(
                      '₹$selling',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: orange,
                      ),
                    ),
                    const SizedBox(width: 7),
                    if (original != selling)
                      Text(
                        '₹$original',
                        style: const TextStyle(
                          color: Colors.grey,
                          decoration: TextDecoration.lineThrough,
                        ),
                      ),
                  ],
                ),
                Text(
                  '$unit • Stock: $stock • ${deliveryMinutes} mins',
                  style: const TextStyle(color: grey, fontSize: 12),
                ),
                if (description.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: grey, fontSize: 11),
                    ),
                  ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: available
                        ? Colors.green.shade50
                        : Colors.red.shade50,
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Text(
                    available ? 'AVAILABLE' : 'UNAVAILABLE',
                    style: TextStyle(
                      color: available ? Colors.green : Colors.red,
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'edit') {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        AddProductPage(productId: id, existingData: data),
                  ),
                );
              } else if (value == 'delete') {
                deleteProduct(id, image);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('Edit')),
              PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
    );
  }
}

// ============================================================
// FESTIVAL POSTERS / HOME BANNERS (branch-scoped)
// ============================================================
class AdminFestivalPostersPage extends StatefulWidget {
  const AdminFestivalPostersPage({super.key});

  @override
  State<AdminFestivalPostersPage> createState() =>
      _AdminFestivalPostersPageState();
}

class _AdminFestivalPostersPageState extends State<AdminFestivalPostersPage> {
  final _picker = ImagePicker();
  final _title = TextEditingController();
  final _subtitle = TextEditingController();
  final _start = TextEditingController();
  final _end = TextEditingController();
  XFile? _image;
  bool _saving = false;
  bool _enabled = true;
  bool _autoSchedule = true;

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _pickPoster() async {
    final image = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
      maxWidth: 1800,
    );
    if (image != null && mounted) setState(() => _image = image);
  }

  DateTime? _parseDate(String value, {bool end = false}) {
    final v = value.trim();
    if (v.isEmpty) return null;
    final parsed = DateTime.tryParse(v);
    if (parsed == null) return null;
    return end
        ? DateTime(parsed.year, parsed.month, parsed.day, 23, 59, 59)
        : DateTime(parsed.year, parsed.month, parsed.day);
  }

  Future<String> _uploadPoster() async {
    if (_image == null) throw Exception('पहले poster image चुनें');
    const cloudName = 'f8ov5nkt';
    const uploadPreset = 'flashcart_products';
    final uri = Uri.parse(
      'https://api.cloudinary.com/v1_1/$cloudName/image/upload',
    );
    final request = http.MultipartRequest('POST', uri)
      ..fields['upload_preset'] = uploadPreset;
    request.files.add(await http.MultipartFile.fromPath('file', _image!.path));
    final response = await request.send();
    final body = await response.stream.bytesToString();
    if (response.statusCode != 200)
      throw Exception('Poster upload failed (${response.statusCode})');
    final result = jsonDecode(body) as Map<String, dynamic>;
    final url = result['secure_url']?.toString();
    if (url == null || url.isEmpty) throw Exception('Poster URL नहीं मिला');
    return url;
  }

  Future<void> _savePoster() async {
    if (_title.text.trim().isEmpty) {
      _message('Poster का title भरें');
      return;
    }
    if (_image == null) {
      _message('Poster image चुनें');
      return;
    }
    final start = _parseDate(_start.text);
    final end = _parseDate(_end.text, end: true);
    if (_autoSchedule &&
        (_start.text.trim().isEmpty ||
            _end.text.trim().isEmpty ||
            start == null ||
            end == null)) {
      _message('Schedule के लिए Start और End date YYYY-MM-DD में भरें');
      return;
    }
    if (start != null && end != null && end.isBefore(start)) {
      _message('End date, Start date से पहले नहीं हो सकती');
      return;
    }
    setState(() => _saving = true);
    try {
      final imageUrl = await _uploadPoster();
      await FirebaseFirestore.instance.collection('homeBanners').add({
        'title': _title.text.trim(),
        'subtitle': _subtitle.text.trim(),
        'imageUrl': imageUrl,
        'branchId': currentAdminBranchId,
        'branchName': currentAdminBranchName,
        'enabled': _enabled,
        'autoSchedule': _autoSchedule,
        'startAt': start == null ? null : Timestamp.fromDate(start),
        'endAt': end == null ? null : Timestamp.fromDate(end),
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      _title.clear();
      _subtitle.clear();
      _start.clear();
      _end.clear();
      if (mounted)
        setState(() {
          _image = null;
          _enabled = true;
          _autoSchedule = true;
        });
      _message(
        'Poster save हो गया। Customer App में enabled poster अपने-आप हर 5 सेकंड में बदलेगा।',
      );
    } catch (e) {
      _message('Poster save नहीं हुआ: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _toggle(String id, bool value) async {
    try {
      await FirebaseFirestore.instance.collection('homeBanners').doc(id).update(
        {'enabled': value, 'updatedAt': FieldValue.serverTimestamp()},
      );
    } catch (e) {
      _message('Status update नहीं हुआ: $e');
    }
  }

  Future<void> _delete(String id) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Poster delete करें?'),
        content: const Text('यह banner Firestore list से हट जाएगा।'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await FirebaseFirestore.instance
          .collection('homeBanners')
          .doc(id)
          .delete();
    } catch (e) {
      _message('Delete नहीं हुआ: $e');
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _subtitle.dispose();
    _start.dispose();
    _end.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFF6F7FB),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Add Festival / Offer Poster',
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Poster image चुनें, title और तारीख set करें। Scheduled poster की active date Customer App में भी लागू करने के लिए उसे homeBanners से read करना होगा.',
                  style: TextStyle(color: grey),
                ),
                const SizedBox(height: 14),
                InkWell(
                  onTap: _pickPoster,
                  child: Container(
                    height: 170,
                    width: double.infinity,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF2E8),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: _image == null
                        ? const Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.add_photo_alternate_rounded,
                                size: 42,
                                color: orange,
                              ),
                              SizedBox(height: 8),
                              Text('Choose poster from gallery'),
                            ],
                          )
                        : ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: Image.file(
                              File(_image!.path),
                              width: double.infinity,
                              height: 170,
                              fit: BoxFit.cover,
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _title,
                  decoration: inputDecoration(
                    'Poster title',
                    Icons.title_rounded,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _subtitle,
                  decoration: inputDecoration(
                    'Subtitle / offer line (optional)',
                    Icons.short_text_rounded,
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Automatic date schedule'),
                  subtitle: const Text(
                    'Poster active केवल Start और End date के बीच रहेगा',
                  ),
                  value: _autoSchedule,
                  onChanged: (v) => setState(() => _autoSchedule = v),
                ),
                if (_autoSchedule) ...[
                  TextField(
                    controller: _start,
                    decoration: inputDecoration(
                      'Start date (YYYY-MM-DD)',
                      Icons.calendar_today_rounded,
                    ),
                    keyboardType: TextInputType.datetime,
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _end,
                    decoration: inputDecoration(
                      'End date (YYYY-MM-DD)',
                      Icons.event_rounded,
                    ),
                    keyboardType: TextInputType.datetime,
                  ),
                ],
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Enable poster'),
                  value: _enabled,
                  onChanged: (v) => setState(() => _enabled = v),
                ),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _saving ? null : _savePoster,
                    icon: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.cloud_upload_rounded),
                    label: Text(
                      _saving ? 'Uploading...' : 'UPLOAD & SAVE POSTER',
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: orange,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.all(14),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          const Text(
            'Saved Posters',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance
                .collection('homeBanners')
                .where('branchId', isEqualTo: currentAdminBranchId)
                .snapshots(),
            builder: (context, snap) {
              if (snap.hasError)
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Posters load नहीं हुए। Firestore Rules और collection permissions जाँचें.',
                  ),
                );
              if (!snap.hasData)
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(20),
                    child: CircularProgressIndicator(color: orange),
                  ),
                );
              final docs = snap.data!.docs.toList()
                ..sort(
                  (a, b) =>
                      ((b.data()['createdAt'] as Timestamp?)
                                  ?.millisecondsSinceEpoch ??
                              0)
                          .compareTo(
                            (a.data()['createdAt'] as Timestamp?)
                                    ?.millisecondsSinceEpoch ??
                                0,
                          ),
                );
              if (docs.isEmpty)
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('अभी कोई poster save नहीं है।'),
                );
              return Column(
                children: docs.map((doc) {
                  final d = doc.data();
                  final enabled = d['enabled'] == true;
                  final url = d['imageUrl']?.toString() ?? '';
                  final start = d['startAt'] is Timestamp
                      ? (d['startAt'] as Timestamp)
                            .toDate()
                            .toString()
                            .split(' ')
                            .first
                      : 'No start';
                  final end = d['endAt'] is Timestamp
                      ? (d['endAt'] as Timestamp)
                            .toDate()
                            .toString()
                            .split(' ')
                            .first
                      : 'No end';
                  return Card(
                    margin: const EdgeInsets.only(bottom: 10),
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: url.isEmpty
                                ? const SizedBox(
                                    width: 76,
                                    height: 76,
                                    child: Icon(Icons.image_not_supported),
                                  )
                                : Image.network(
                                    url,
                                    width: 76,
                                    height: 76,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) =>
                                        const SizedBox(
                                          width: 76,
                                          height: 76,
                                          child: Icon(Icons.broken_image),
                                        ),
                                  ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  d['title']?.toString() ?? 'Poster',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Text(
                                  '$start → $end',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: grey,
                                  ),
                                ),
                                Switch(
                                  value: enabled,
                                  onChanged: (v) => _toggle(doc.id, v),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: () => _delete(doc.id),
                            icon: const Icon(
                              Icons.delete_outline_rounded,
                              color: Colors.red,
                            ),
                          ),
                        ],
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
  }
}

// ============================================================
// ADD / EDIT PRODUCT
// ============================================================

class AddProductPage extends StatefulWidget {
  final String? productId;
  final Map<String, dynamic>? existingData;

  const AddProductPage({super.key, this.productId, this.existingData});

  bool get editing => productId != null;

  @override
  State<AddProductPage> createState() => _AddProductPageState();
}

class _AddProductPageState extends State<AddProductPage> {
  final nameController = TextEditingController();
  final originalPriceController = TextEditingController();
  final discountController = TextEditingController();
  final unitController = TextEditingController();
  final stockController = TextEditingController();
  final descriptionController = TextEditingController();
  final deliveryMinutesController = TextEditingController(text: '10');

  final picker = ImagePicker();

  File? selectedImage;
  String existingImageUrl = '';

  String selectedCategory = 'General';
  bool available = true;
  bool saving = false;

  double sellingPrice = 0;

  @override
  void initState() {
    super.initState();

    final data = widget.existingData;

    if (data != null) {
      nameController.text = data['name']?.toString() ?? '';

      originalPriceController.text = data['originalPrice']?.toString() ?? '';

      discountController.text = data['discount']?.toString() ?? '';

      unitController.text = data['unit']?.toString() ?? '';

      stockController.text = data['stock']?.toString() ?? '';
      descriptionController.text = data['description']?.toString() ?? '';
      deliveryMinutesController.text =
          data['deliveryTimeMins']?.toString() ?? '10';

      selectedCategory = data['category']?.toString() ?? 'General';

      available = data['available'] ?? true;

      existingImageUrl = data['imageUrl']?.toString() ?? '';

      calculatePrice();
    }

    originalPriceController.addListener(calculatePrice);
    discountController.addListener(calculatePrice);
  }

  void calculatePrice() {
    final original = double.tryParse(originalPriceController.text) ?? 0;

    final discount = double.tryParse(discountController.text) ?? 0;

    final price = original - (original * discount / 100);

    if (mounted) {
      setState(() {
        sellingPrice = price < 0 ? 0 : price;
      });
    }
  }

  Future<void> pickImage() async {
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 80,
      maxWidth: 1200,
    );

    if (picked == null) return;

    setState(() {
      selectedImage = File(picked.path);
    });
  }

  Future<String> uploadImage() async {
    if (selectedImage == null) {
      return existingImageUrl;
    }

    const cloudName = 'f8ov5nkt';
    const uploadPreset = 'flashcart_products';

    final uri = Uri.parse(
      'https://api.cloudinary.com/v1_1/$cloudName/image/upload',
    );

    final request = http.MultipartRequest('POST', uri);

    request.fields['upload_preset'] = uploadPreset;

    request.files.add(
      await http.MultipartFile.fromPath('file', selectedImage!.path),
    );

    final response = await request.send();
    final responseBody = await response.stream.bytesToString();

    if (response.statusCode != 200) {
      throw Exception(
        'Cloudinary upload failed (${response.statusCode}): $responseBody',
      );
    }

    final result = jsonDecode(responseBody) as Map<String, dynamic>;
    final secureUrl = result['secure_url']?.toString();

    if (secureUrl == null || secureUrl.isEmpty) {
      throw Exception('Cloudinary ने image URL नहीं दिया');
    }

    return secureUrl;
  }

  Future<void> saveProduct() async {
    final name = nameController.text.trim();
    final original = double.tryParse(originalPriceController.text) ?? 0;
    final discount = double.tryParse(discountController.text) ?? 0;
    final stock = int.tryParse(stockController.text) ?? 0;
    final unit = unitController.text.trim();
    final deliveryMinutes = int.tryParse(deliveryMinutesController.text) ?? 10;

    if (name.isEmpty) {
      message('Product name भरें');
      return;
    }

    if (original <= 0) {
      message('Original price सही भरें');
      return;
    }

    if (unit.isEmpty) {
      message('Unit भरें');
      return;
    }

    if (stock < 0) {
      message('Stock सही भरें');
      return;
    }
    if (deliveryMinutes < 1 || deliveryMinutes > 240) {
      message('Delivery time 1 से 240 मिनट के बीच भरें');
      return;
    }

    setState(() => saving = true);

    try {
      final imageUrl = await uploadImage();

      final data = <String, dynamic>{
        'name': name,
        'originalPrice': original,
        'discount': discount,
        'sellingPrice': sellingPrice,
        'unit': unit,
        'description': descriptionController.text.trim(),
        'deliveryTimeMins': deliveryMinutes,
        'category': selectedCategory,
        'stock': stock,
        'available': available,
        'imageUrl': imageUrl,
        'branchId': currentAdminBranchId,
        'branchName': currentAdminBranchName,
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (widget.editing) {
        final productRef = FirebaseFirestore.instance
            .collection('products')
            .doc(widget.productId);
        final existing = await productRef.get();
        final existingData = existing.data() ?? <String, dynamic>{};
        if (!existing.exists ||
            (existingData['branchId'] ?? '').toString() !=
                currentAdminBranchId) {
          throw Exception('यह Product आपकी Branch का नहीं है।');
        }
        await productRef.update(data);
      } else {
        data['createdAt'] = FieldValue.serverTimestamp();
        await FirebaseFirestore.instance.collection('products').add(data);
      }

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.editing
                ? 'Product updated successfully'
                : 'Product added successfully',
          ),
        ),
      );

      Navigator.pop(context);
    } catch (e) {
      message('Product save नहीं हुआ: $e');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  void message(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  void dispose() {
    nameController.dispose();
    originalPriceController.dispose();
    discountController.dispose();
    unitController.dispose();
    stockController.dispose();
    descriptionController.dispose();
    deliveryMinutesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.editing ? 'Edit Product' : 'Add Product';

    return Scaffold(
      appBar: AppBar(
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(18),
        child: Column(
          children: [
            imagePickerBox(),
            const SizedBox(height: 20),
            field(nameController, 'Product Name', Icons.shopping_bag_outlined),
            const SizedBox(height: 14),
            TextField(
              controller: descriptionController,
              minLines: 3,
              maxLines: 6,
              decoration:
                  inputDecoration(
                    'Product Description',
                    Icons.description_outlined,
                  ).copyWith(
                    hintText:
                        'Product details, quality, ingredients / use, notes...',
                    alignLabelWithHint: true,
                  ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: field(
                    originalPriceController,
                    'Original Price',
                    Icons.currency_rupee,
                    keyboard: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: field(
                    discountController,
                    'Discount %',
                    Icons.percent,
                    keyboard: TextInputType.number,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 15),
            sellingPriceBox(),
            const SizedBox(height: 15),
            Row(
              children: [
                Expanded(
                  child: field(unitController, 'Unit', Icons.scale_outlined),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: field(
                    stockController,
                    'Stock',
                    Icons.inventory_2_outlined,
                    keyboard: TextInputType.number,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 15),
            categorySelector(),
            const SizedBox(height: 14),
            field(
              deliveryMinutesController,
              'Estimated Delivery Time (minutes)',
              Icons.schedule_rounded,
              keyboard: TextInputType.number,
            ),
            const SizedBox(height: 10),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Product Available',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Text(
                available
                    ? 'Customer को product दिखाई देगा'
                    : 'Customer को product unavailable दिखाई देगा',
              ),
              value: available,
              activeThumbColor: orange,
              onChanged: (value) {
                setState(() => available = value);
              },
            ),
            const SizedBox(height: 25),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton.icon(
                onPressed: saving ? null : saveProduct,
                style: ElevatedButton.styleFrom(
                  backgroundColor: orange,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                icon: saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.save_rounded),
                label: Text(
                  saving
                      ? 'Saving...'
                      : widget.editing
                      ? 'UPDATE PRODUCT'
                      : 'SAVE PRODUCT',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),
            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }

  Widget imagePickerBox() {
    final hasImage = selectedImage != null || existingImageUrl.isNotEmpty;

    return InkWell(
      onTap: pickImage,
      borderRadius: BorderRadius.circular(24),
      child: Container(
        width: double.infinity,
        height: 210,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: hasImage
            ? ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: selectedImage != null
                    ? Image.file(selectedImage!, fit: BoxFit.cover)
                    : Image.network(existingImageUrl, fit: BoxFit.cover),
              )
            : const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.add_a_photo_rounded, size: 48, color: orange),
                  SizedBox(height: 10),
                  Text(
                    'Add Product Photo',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
                  ),
                  SizedBox(height: 5),
                  Text('Gallery से photo चुनें', style: TextStyle(color: grey)),
                ],
              ),
      ),
    );
  }

  Widget sellingPriceBox() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [orange, Color(0xFFFF9F43)]),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          const Icon(Icons.local_offer_rounded, color: Colors.white, size: 32),
          const SizedBox(width: 14),
          const Expanded(
            child: Text(
              'Selling Price',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Text(
            '₹${sellingPrice.toStringAsFixed(0)}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 27,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }

  Widget field(
    TextEditingController controller,
    String label,
    IconData icon, {
    TextInputType keyboard = TextInputType.text,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboard,
      decoration: inputDecoration(label, icon),
    );
  }

  Widget categorySelector() {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('categories')
          .where('branchId', isEqualTo: currentAdminBranchId)
          .snapshots(),
      builder: (_, snapshot) {
        final categories = <String>['General'];

        if (snapshot.hasData) {
          for (final doc in snapshot.data!.docs) {
            final data = doc.data() as Map<String, dynamic>;

            final name = data['name']?.toString();

            if (name != null && name.isNotEmpty && !categories.contains(name)) {
              categories.add(name);
            }
          }
        }

        if (!categories.contains(selectedCategory)) {
          selectedCategory = 'General';
        }

        return DropdownButtonFormField<String>(
          initialValue: selectedCategory,
          decoration: inputDecoration('Category', Icons.category_outlined),
          items: categories
              .map(
                (category) =>
                    DropdownMenuItem(value: category, child: Text(category)),
              )
              .toList(),
          onChanged: (value) {
            if (value != null) {
              setState(() => selectedCategory = value);
            }
          },
        );
      },
    );
  }
}

// ============================================================
// CATEGORIES
// ============================================================

class CategoriesPage extends StatefulWidget {
  const CategoriesPage({super.key});

  @override
  State<CategoriesPage> createState() => _CategoriesPageState();
}

class _CategoriesPageState extends State<CategoriesPage> {
  final controller = TextEditingController();

  Future<void> addCategory() async {
    final name = controller.text.trim();

    if (name.isEmpty) return;

    await FirebaseFirestore.instance.collection('categories').add({
      'name': name,
      'branchId': currentAdminBranchId,
      'branchName': currentAdminBranchName,
      'createdAt': FieldValue.serverTimestamp(),
    });

    controller.clear();

    if (mounted) Navigator.pop(context);
  }

  Future<void> showAddCategory() async {
    controller.clear();

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Add Category'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'e.g. Fruits'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(onPressed: addCategory, child: const Text('Add')),
        ],
      ),
    );
  }

  Future<void> deleteCategory(String id) async {
    final ref = FirebaseFirestore.instance.collection('categories').doc(id);
    final snap = await ref.get();
    if (!snap.exists ||
        (snap.data()?['branchId'] ?? '').toString() != currentAdminBranchId) {
      throw Exception('यह Category आपकी Branch की नहीं है।');
    }
    await ref.delete();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: orange,
        foregroundColor: Colors.white,
        onPressed: showAddCategory,
        icon: const Icon(Icons.add),
        label: const Text('Add Category'),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('categories')
            .where('branchId', isEqualTo: currentAdminBranchId)
            .snapshots(),
        builder: (_, snapshot) {
          if (!snapshot.hasData) {
            return const Center(
              child: CircularProgressIndicator(color: orange),
            );
          }

          final docs = snapshot.data!.docs;

          if (docs.isEmpty) {
            return const Center(
              child: Text(
                'अभी कोई category नहीं है.\nAdd Category से शुरू करें।',
                textAlign: TextAlign.center,
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: docs.length,
            itemBuilder: (_, index) {
              final doc = docs[index];
              final data = doc.data() as Map<String, dynamic>;

              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(17),
                ),
                child: ListTile(
                  leading: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: lightOrange,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.category_rounded, color: orange),
                  ),
                  title: Text(
                    data['name']?.toString() ?? '',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  trailing: IconButton(
                    onPressed: () => deleteCategory(doc.id),
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
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
// ORDERS
// ============================================================

class OrdersPage extends StatelessWidget {
  const OrdersPage({super.key});

  Future<void> manuallyAssignOrder(BuildContext context, String orderId) async {
    final db = FirebaseFirestore.instance;
    try {
      final orderSnap = await db.collection('orders').doc(orderId).get();
      if (!orderSnap.exists) throw Exception('Order not found');
      final orderData = orderSnap.data() ?? <String, dynamic>{};
      if ((orderData['branchId'] ?? '').toString() != currentAdminBranchId) {
        throw Exception('यह order आपकी Branch का नहीं है।');
      }
      final currentStatus =
          orderData['status']?.toString().trim().toLowerCase() ?? '';
      if (currentStatus == 'delivered' ||
          currentStatus == 'cancelled' ||
          currentStatus == 'cancelled by customer') {
        throw Exception('यह order पहले ही complete/cancelled है।');
      }

      final partnerSnap = await db
          .collection('deliveryPartners')
          .where('branchId', isEqualTo: currentAdminBranchId)
          .where('active', isEqualTo: true)
          .get();
      final partners = partnerSnap.docs.where((doc) {
        final d = doc.data();
        final activeOrder = d['activeOrderId']?.toString().trim() ?? '';
        return activeOrder.isEmpty;
      }).toList();

      if (partners.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('कोई available Delivery Partner नहीं मिला।'),
            ),
          );
        }
        return;
      }

      if (!context.mounted) return;
      final selectedId = await showDialog<String>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title: const Text('Assign Delivery Partner'),
            content: SizedBox(
              width: 420,
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: partners.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, index) {
                  final doc = partners[index];
                  final d = doc.data();
                  final name = d['name']?.toString().trim();
                  final phone =
                      d['phone']?.toString() ?? d['mobile']?.toString() ?? '';
                  final online = d['online'] == true;
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: online
                          ? Colors.green.shade50
                          : Colors.orange.shade50,
                      child: Icon(
                        Icons.delivery_dining_rounded,
                        color: online ? Colors.green : orange,
                      ),
                    ),
                    title: Text(
                      name == null || name.isEmpty ? 'Delivery Partner' : name,
                    ),
                    subtitle: Text(
                      '${phone.isEmpty ? 'No phone' : phone} • ${online ? 'Online' : 'Offline'}',
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.pop(dialogContext, doc.id),
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
            ],
          );
        },
      );

      if (selectedId == null) return;

      final orderRef = db.collection('orders').doc(orderId);
      final partnerRef = db.collection('deliveryPartners').doc(selectedId);
      await db.runTransaction((transaction) async {
        final freshOrder = await transaction.get(orderRef);
        final freshPartner = await transaction.get(partnerRef);
        if (!freshOrder.exists || !freshPartner.exists)
          throw Exception('Order/Partner not found');
        final freshOrderData = freshOrder.data() ?? <String, dynamic>{};
        final freshPartnerData = freshPartner.data() ?? <String, dynamic>{};
        if ((freshOrderData['branchId'] ?? '').toString() !=
                currentAdminBranchId ||
            (freshPartnerData['branchId'] ?? '').toString() !=
                currentAdminBranchId) {
          throw Exception(
            'Order और Delivery Partner एक ही Branch के होने चाहिए।',
          );
        }
        final status =
            freshOrderData['status']?.toString().trim().toLowerCase() ?? '';
        if (status == 'delivered' ||
            status == 'cancelled' ||
            status == 'cancelled by customer') {
          throw Exception('Order अब assign नहीं किया जा सकता।');
        }
        if (freshPartnerData['active'] == false)
          throw Exception('Partner inactive है।');
        final activeOrder =
            freshPartnerData['activeOrderId']?.toString().trim() ?? '';
        if (activeOrder.isNotEmpty && activeOrder != orderId)
          throw Exception('Partner अभी दूसरे order पर है।');
        final partnerName = freshPartnerData['name']?.toString().trim();
        transaction.update(orderRef, {
          'deliveryPartnerId': selectedId,
          'deliveryPartnerName': partnerName == null || partnerName.isEmpty
              ? 'Delivery Partner'
              : partnerName,
          'deliveryPartnerPhone':
              freshPartnerData['phone'] ??
              freshPartnerData['mobile'] ??
              freshPartnerData['mobileNumber'] ??
              '',
          'assignmentStatus': 'manually_assigned',
          'assignedAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
        transaction.set(partnerRef, {
          'availableForOrder': false,
          'activeOrderId': orderId,
          'lastAssignedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

        final queueRef = db.collection('deliveryQueue').doc(orderId);
        transaction.set(queueRef, {
          'orderId': orderId,
          'branchId': currentAdminBranchId,
          'branchName': currentAdminBranchName,
          'userId':
              freshOrderData['userId'] ?? freshOrderData['customerId'] ?? '',
          'status': 'assigned',
          'assignedPartnerId': selectedId,
          'assignedAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      });

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Order manually assigned successfully ✅'),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Manual assignment failed: $e')));
      }
    }
  }

  Future<void> updateStatus(String orderId, String status) async {
    final db = FirebaseFirestore.instance;
    final orderRef = db.collection('orders').doc(orderId);

    final snap = await orderRef.get();
    if (!snap.exists) return;

    final data = snap.data() ?? <String, dynamic>{};
    if ((data['branchId'] ?? '').toString() != currentAdminBranchId) {
      throw Exception('यह order आपकी Branch का नहीं है।');
    }
    final partnerId = data['deliveryPartnerId']?.toString() ?? '';

    if (data['status']?.toString() == 'Delivered' && status == 'Delivered') {
      return;
    }

    await orderRef.update({
      'status': status,
      'updatedAt': FieldValue.serverTimestamp(),
    });

    // A completed/cancelled delivery becomes eligible for the next order.
    if (partnerId.isNotEmpty &&
        (status == 'Delivered' ||
            status.toLowerCase() == 'cancelled' ||
            status.toLowerCase() == 'cancelled by customer')) {
      final partnerRef = db.collection('deliveryPartners').doc(partnerId);
      await db.runTransaction((transaction) async {
        final partnerSnap = await transaction.get(partnerRef);
        final partnerData = partnerSnap.data() ?? <String, dynamic>{};
        final dateKey = adminIncentiveDateKey();
        final storedDate = partnerData['incentiveDate']?.toString() ?? '';
        final oldTodayCount = storedDate == dateKey
            ? ((partnerData['deliveredOrdersToday'] is num)
                  ? (partnerData['deliveredOrdersToday'] as num).toInt()
                  : int.tryParse(
                          partnerData['deliveredOrdersToday']?.toString() ?? '',
                        ) ??
                        0)
            : 0;
        final incentiveDelta = await applyAdminDeliveryIncentive(
          db: db,
          partnerId: partnerId,
          transaction: transaction,
          partnerData: partnerData,
          nextDeliveredToday: oldTodayCount + 1,
        );
        final oldPaid = storedDate == dateKey
            ? adminMoney(partnerData['incentivePaidToday'])
            : 0.0;
        final currentTotal = adminMoney(
          partnerData['totalEarnings'] ??
              partnerData['earnings'] ??
              partnerData['walletBalance'] ??
              0,
        );
        final deliveredRaw = partnerData['deliveredOrderCount'];
        final deliveredCount = deliveredRaw is num
            ? deliveredRaw.toInt()
            : int.tryParse(deliveredRaw?.toString() ?? '') ?? 0;
        transaction.set(partnerRef, {
          // Delivered/cancelled means the partner is automatically OFFLINE.
          'online': false,
          'availableForOrder': false,
          'activeOrderId': FieldValue.delete(),
          'lastAvailableAt': FieldValue.serverTimestamp(),
          'lastOfflineAt': FieldValue.serverTimestamp(),
          'autoOfflineAfterDelivery': true,
          'adminOnlineEnabled': false,
          'requiresAdminReactivation': true,
          'deliveredOrdersToday': oldTodayCount + 1,
          'deliveredOrderCount': deliveredCount + 1,
          'incentiveDate': dateKey,
          'incentivePaidToday': oldPaid + incentiveDelta,
          'todayIncentive': oldPaid + incentiveDelta,
          'lastIncentiveAmount': incentiveDelta,
          'totalEarnings': currentTotal + incentiveDelta,
          'walletBalance': currentTotal + incentiveDelta,
          'earningsUpdatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        transaction.update(orderRef, {
          'incentiveAmount': incentiveDelta,
          'incentiveDate': dateKey,
          'incentiveTargetOrders': oldTodayCount + 1,
        });
      });
    }

    // When an order has no partner, try the queue again immediately.
    if (partnerId.isEmpty &&
        status != 'Delivered' &&
        status.toLowerCase() != 'cancelled') {
      await AdminAutomation.autoAssignOrder(orderId);
    }
  }

  double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();

    if (value is String) {
      final cleaned = value.replaceAll(RegExp(r'[^0-9.\-]'), '');
      return double.tryParse(cleaned) ?? 0;
    }

    return 0;
  }

  double _extractOrderTotal(Map<String, dynamic> data) {
    const directKeys = [
      'total',
      'totalAmount',
      'total_amount',
      'grandTotal',
      'grand_total',
      'orderTotal',
      'order_total',
      'totalPrice',
      'total_price',
      'finalTotal',
      'final_total',
      'payableAmount',
      'payable_amount',
      'amount',
    ];

    for (final key in directKeys) {
      if (data.containsKey(key)) {
        final value = _toDouble(data[key]);
        if (value > 0) return value;
      }
    }

    const mapKeys = ['summary', 'priceDetails', 'price_details', 'pricing'];
    for (final mapKey in mapKeys) {
      final value = data[mapKey];
      if (value is Map) {
        for (final key in directKeys) {
          if (value.containsKey(key)) {
            final amount = _toDouble(value[key]);
            if (amount > 0) return amount;
          }
        }
      }
    }

    final items = data['items'] ?? data['orderItems'] ?? data['products'];
    if (items is List) {
      double itemTotal = 0;

      for (final item in items) {
        if (item is! Map) continue;

        final price = _toDouble(
          item['sellingPrice'] ??
              item['price'] ??
              item['unitPrice'] ??
              item['salePrice'] ??
              0,
        );

        final quantity = _toDouble(
          item['quantity'] ?? item['qty'] ?? item['count'] ?? 1,
        );

        itemTotal += price * (quantity <= 0 ? 1 : quantity);
      }

      itemTotal += _toDouble(
        data['deliveryFee'] ??
            data['deliveryCharge'] ??
            data['delivery_charge'] ??
            0,
      );

      itemTotal += _toDouble(
        data['tax'] ?? data['gst'] ?? data['taxAmount'] ?? 0,
      );

      itemTotal -= _toDouble(
        data['discountAmount'] ?? data['discount_amount'] ?? 0,
      );

      if (itemTotal > 0) return itemTotal;
    }

    return 0;
  }

  String _formatAmount(double amount) {
    if (amount == amount.roundToDouble()) {
      return amount.toInt().toString();
    }
    return amount.toStringAsFixed(2);
  }

  DateTime _dateFromData(Map<String, dynamic> data) {
    final value = data['createdAt'] ?? data['updatedAt'] ?? data['timestamp'];

    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;

    if (value is String) {
      return DateTime.tryParse(value) ?? DateTime.fromMillisecondsSinceEpoch(0);
    }

    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      // Do not use orderBy('createdAt') so old orders without createdAt
      // are also displayed.
      stream: FirebaseFirestore.instance
          .collection('orders')
          .where('branchId', isEqualTo: currentAdminBranchId)
          .snapshots(),
      builder: (_, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(color: orange));
        }

        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Orders load करने में समस्या हुई.\n${snapshot.error}',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        final docs = [...(snapshot.data?.docs ?? [])];

        docs.sort((a, b) {
          final aData = a.data() as Map<String, dynamic>;
          final bData = b.data() as Map<String, dynamic>;
          return _dateFromData(bData).compareTo(_dateFromData(aData));
        });

        if (docs.isEmpty) {
          return const Center(
            child: Text('अभी कोई order नहीं है।', textAlign: TextAlign.center),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: docs.length,
          itemBuilder: (_, index) {
            final doc = docs[index];
            final data = doc.data() as Map<String, dynamic>;

            final orderId = doc.id;
            final status =
                (data['cancelled'] == true ||
                    data['cancelRequested'] == true ||
                    data['cancellationRequested'] == true)
                ? 'Cancelled'
                : (data['status']?.toString() ?? 'Order Placed');
            final total = _extractOrderTotal(data);

            final phone =
                data['phone']?.toString() ??
                data['customerPhone']?.toString() ??
                data['mobile']?.toString() ??
                '';

            final customerName =
                data['customerName']?.toString() ??
                data['name']?.toString() ??
                '';

            return Container(
              margin: const EdgeInsets.only(bottom: 13),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.shopping_bag_rounded, color: orange),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          'Order #${orderId.substring(0, orderId.length > 8 ? 8 : orderId.length)}',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      Text(
                        '₹${_formatAmount(total)}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 18,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  if (customerName.isNotEmpty)
                    Text(
                      'Customer: $customerName',
                      style: const TextStyle(color: grey),
                    ),

                  if (phone.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'Phone: $phone',
                        style: const TextStyle(color: grey),
                      ),
                    ),

                  // Product names, quantities and images from the order snapshot.
                  _adminOrderItems(data),
                  if (status.toLowerCase().contains('cancel'))
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(top: 10),
                      padding: const EdgeInsets.all(11),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.red.shade200),
                      ),
                      child: Text(
                        'ORDER CANCELLED${(data['cancellationReason'] ?? data['cancelReason'] ?? '').toString().trim().isEmpty ? '' : '\nकारण: ${data['cancellationReason'] ?? data['cancelReason']}'}',
                        style: TextStyle(
                          color: Colors.red.shade800,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),

                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Text(
                      data['deliveryPartnerId']?.toString().isNotEmpty == true
                          ? 'Delivery Partner: ${data['deliveryPartnerName']?.toString() ?? 'Assigned'}'
                          : 'Delivery Partner: Not assigned yet',
                      style: TextStyle(
                        color:
                            data['deliveryPartnerId']?.toString().isNotEmpty ==
                                true
                            ? Colors.green.shade700
                            : Colors.orange.shade800,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (data['deliveryPartnerId']?.toString().isNotEmpty ==
                      true) ...[
                    if ((data['deliveryPartnerPhone'] ?? '')
                        .toString()
                        .trim()
                        .isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          'Partner Phone: ${data['deliveryPartnerPhone']}',
                          style: const TextStyle(color: grey, fontSize: 12.5),
                        ),
                      ),
                    if ((data['assignmentStatus'] ?? '')
                        .toString()
                        .trim()
                        .isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          'Assignment: ${data['assignmentStatus']}',
                          style: const TextStyle(color: grey, fontSize: 12.5),
                        ),
                      ),
                  ],

                  if (data['deliveryCurrentLatitude'] is num &&
                      data['deliveryCurrentLongitude'] is num)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          final lat = (data['deliveryCurrentLatitude'] as num)
                              .toDouble();
                          final lng = (data['deliveryCurrentLongitude'] as num)
                              .toDouble();
                          final uri = Uri.parse(
                            'https://www.google.com/maps/search/?api=1&query=$lat,$lng',
                          );
                          if (await canLaunchUrl(uri)) {
                            await launchUrl(
                              uri,
                              mode: LaunchMode.externalApplication,
                            );
                          }
                        },
                        icon: const Icon(Icons.my_location_rounded),
                        label: const Text('Open Live Partner Location'),
                      ),
                    ),

                  const SizedBox(height: 12),

                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed:
                        [
                          'delivered',
                          'cancelled',
                          'cancelled by customer',
                        ].contains(status.toLowerCase())
                        ? null
                        : () => manuallyAssignOrder(context, orderId),
                    icon: const Icon(Icons.person_add_alt_1_rounded),
                    label: Text(
                      data['deliveryPartnerId']?.toString().trim().isNotEmpty ==
                              true
                          ? 'Reassign Delivery Partner'
                          : 'Assign Delivery Partner',
                    ),
                  ),

                  if (![
                    'delivered',
                    'cancelled',
                    'cancelled by customer',
                  ].contains(status.toLowerCase()))
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: () async {
                          final reason = await showDialog<String>(
                            context: context,
                            builder: (ctx) {
                              final controller = TextEditingController();
                              return AlertDialog(
                                title: const Text('Order Cancel करें?'),
                                content: TextField(
                                  controller: controller,
                                  maxLines: 2,
                                  decoration: const InputDecoration(
                                    labelText: 'कारण (वैकल्पिक)',
                                  ),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(ctx),
                                    child: const Text('वापस'),
                                  ),
                                  FilledButton(
                                    style: FilledButton.styleFrom(
                                      backgroundColor: Colors.red,
                                    ),
                                    onPressed: () => Navigator.pop(
                                      ctx,
                                      controller.text.trim(),
                                    ),
                                    child: const Text('Cancel Order'),
                                  ),
                                ],
                              );
                            },
                          );
                          if (reason == null) return;
                          try {
                            await FirebaseFirestore.instance
                                .collection('orders')
                                .doc(orderId)
                                .update({
                                  'status': 'Cancelled',
                                  'cancelled': true,
                                  'cancelledBy': 'admin',
                                  'cancellationReason': reason,
                                  'cancelledAt': FieldValue.serverTimestamp(),
                                  'updatedAt': FieldValue.serverTimestamp(),
                                });
                            final partnerId = (data['deliveryPartnerId'] ?? '')
                                .toString()
                                .trim();
                            if (partnerId.isNotEmpty) {
                              await FirebaseFirestore.instance
                                  .collection('deliveryPartners')
                                  .doc(partnerId)
                                  .set({
                                    'activeOrderId': FieldValue.delete(),
                                    'availableForOrder': true,
                                    'lastAvailableAt':
                                        FieldValue.serverTimestamp(),
                                  }, SetOptions(merge: true));
                            }
                            if (context.mounted)
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Order cancelled'),
                                ),
                              );
                          } catch (e) {
                            if (context.mounted)
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Cancel failed: $e')),
                              );
                          }
                        },
                        icon: const Icon(
                          Icons.cancel_outlined,
                          color: Colors.red,
                        ),
                        label: const Text(
                          'Cancel Order',
                          style: TextStyle(color: Colors.red),
                        ),
                      ),
                    ),

                  DropdownButtonFormField<String>(
                    initialValue: orderStatuses.contains(status)
                        ? status
                        : orderStatuses.first,
                    decoration: const InputDecoration(
                      labelText: 'Order Status',
                      border: OutlineInputBorder(),
                    ),
                    items: orderStatuses
                        .map(
                          (item) =>
                              DropdownMenuItem(value: item, child: Text(item)),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        updateStatus(orderId, value);
                      }
                    },
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

Widget _adminOrderItems(Map<String, dynamic> data) {
  final raw =
      data['items'] ??
      data['orderItems'] ??
      data['cartItems'] ??
      data['products'];
  if (raw is! List || raw.isEmpty) {
    return const Padding(
      padding: EdgeInsets.only(top: 8),
      child: Text(
        'Products: item details order में उपलब्ध नहीं हैं।',
        style: TextStyle(color: grey, fontSize: 12),
      ),
    );
  }
  return Container(
    margin: const EdgeInsets.only(top: 10, bottom: 4),
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: const Color(0xFFF8F8F8),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Order Products',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        ...raw.whereType<Map>().map((item) {
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
          final price =
              item['price'] ?? item['sellingPrice'] ?? item['unitPrice'] ?? '';
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 48,
                    height: 48,
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        'Qty: $qty${price.toString().trim().isEmpty ? '' : ' • ₹$price'}',
                        style: const TextStyle(color: grey, fontSize: 12),
                      ),
                    ],
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

// ============================================================
// CUSTOMERS
// ============================================================

class CustomersPage extends StatelessWidget {
  const CustomersPage({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('users').snapshots(),
      builder: (_, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator(color: orange));
        }

        final docs = snapshot.data!.docs;

        if (docs.isEmpty) {
          return const Center(child: Text('अभी कोई customer नहीं मिला।'));
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: docs.length,
          itemBuilder: (_, index) {
            final data = docs[index].data() as Map<String, dynamic>;

            final name = data['name']?.toString() ?? 'Customer';

            final phone =
                data['phone']?.toString() ?? data['mobile']?.toString() ?? '';

            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
              ),
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: lightOrange,
                  child: const Icon(Icons.person, color: orange),
                ),
                title: Text(
                  name,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(phone.isEmpty ? 'Customer' : phone),
              ),
            );
          },
        );
      },
    );
  }
}

// ============================================================
// ADMIN AUTOMATION
// ============================================================

class AdminAutomation {
  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static bool _isUnassigned(Map<String, dynamic> data) {
    final partnerId = data['deliveryPartnerId']?.toString().trim() ?? '';
    if (partnerId.isNotEmpty) return false;

    final status = (data['status'] ?? '').toString().toLowerCase();
    return status != 'delivered' &&
        status != 'cancelled' &&
        status != 'cancelled by customer';
  }

  static DateTime _time(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    if (value is String) {
      return DateTime.tryParse(value) ?? DateTime.fromMillisecondsSinceEpoch(0);
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  static DateTime _partnerQueueTime(Map<String, dynamic> data) {
    return _time(
      data['onlineSince'] ??
          data['onlineAt'] ??
          data['lastOnlineAt'] ??
          data['createdAt'],
    );
  }

  static bool _eligible(Map<String, dynamic> data) {
    if (data['active'] == false) return false;
    if (data['online'] != true) return false;
    // Missing availableForOrder means legacy partners are treated as
    // available, so adding this feature does not break existing partners.
    if (data['availableForOrder'] == false) return false;
    return true;
  }

  static Future<void> autoAssignUnassignedOrders() async {
    final snapshot = await _db
        .collection('orders')
        .where('branchId', isEqualTo: currentAdminBranchId)
        .get();

    final pending = snapshot.docs.where((doc) {
      final data = doc.data();
      return _isUnassigned(data);
    }).toList();

    pending.sort((a, b) {
      final aData = a.data();
      final bData = b.data();
      return _time(
        aData['createdAt'] ?? aData['timestamp'] ?? aData['updatedAt'],
      ).compareTo(
        _time(bData['createdAt'] ?? bData['timestamp'] ?? bData['updatedAt']),
      );
    });

    for (final order in pending) {
      await autoAssignOrder(order.id);
    }
  }

  static Future<bool> autoAssignOrder(String orderId) async {
    // Retry because another admin device can claim a partner at the same
    // moment. The transaction protects the order/partner pair from double
    // assignment.
    for (var attempt = 0; attempt < 5; attempt++) {
      final orderRef = _db.collection('orders').doc(orderId);
      final orderSnap = await orderRef.get();

      if (!orderSnap.exists) return false;
      final orderData = orderSnap.data() ?? <String, dynamic>{};

      if (!_isUnassigned(orderData)) return true;

      if ((orderData['branchId'] ?? '').toString() != currentAdminBranchId) {
        return false;
      }
      final partnersSnap = await _db
          .collection('deliveryPartners')
          .where('branchId', isEqualTo: currentAdminBranchId)
          .get();

      final candidates = partnersSnap.docs.where((doc) {
        return _eligible(doc.data());
      }).toList();

      candidates.sort((a, b) {
        return _partnerQueueTime(a.data())
            .compareTo(_partnerQueueTime(b.data()));
      });

      if (candidates.isEmpty) return false;

      for (final partner in candidates) {
        final partnerRef = _db.collection('deliveryPartners').doc(partner.id);

        try {
          final assigned = await _db.runTransaction<bool>((transaction) async {
            // All reads are completed before writes.
            final freshOrder = await transaction.get(orderRef);
            final freshPartner = await transaction.get(partnerRef);

            if (!freshOrder.exists || !freshPartner.exists) return false;

            final freshOrderData =
                freshOrder.data() as Map<String, dynamic>? ?? {};
            final freshPartnerData =
                freshPartner.data() as Map<String, dynamic>? ?? {};

            // Enforce branch boundary inside the transaction too.
            if ((freshOrderData['branchId'] ?? '').toString() !=
                    currentAdminBranchId ||
                (freshPartnerData['branchId'] ?? '').toString() !=
                    currentAdminBranchId) {
              return false;
            }
            // Someone else already assigned this order.
            if (!_isUnassigned(freshOrderData)) return true;

            // Partner may have gone offline or accepted another order.
            if (!_eligible(freshPartnerData)) return false;

            final partnerName =
                freshPartnerData['name']?.toString() ??
                freshPartnerData['fullName']?.toString() ??
                'Delivery Partner';

            transaction.update(orderRef, {
              'deliveryPartnerId': partner.id,
              'deliveryPartnerName': partnerName,
              'deliveryPartnerPhone':
                  freshPartnerData['phone'] ??
                  freshPartnerData['mobile'] ??
                  freshPartnerData['mobileNumber'] ??
                  '',
              'assignmentStatus': 'assigned',
              'assignedAt': FieldValue.serverTimestamp(),
              'updatedAt': FieldValue.serverTimestamp(),
            });

            transaction.set(partnerRef, {
              'availableForOrder': false,
              'activeOrderId': orderId,
              'lastAssignedAt': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));

            return true;
          });

          if (assigned) return true;
        } catch (_) {
          // Transaction conflict: try the next candidate/re-read the queue.
        }
      }
    }

    return false;
  }
}

// ============================================================
// DELIVERY PARTNERS
// ============================================================

class DeliveryPartnersPage extends StatelessWidget {
  const DeliveryPartnersPage({super.key});

  DateTime _time(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    if (value is String) {
      return DateTime.tryParse(value) ?? DateTime.fromMillisecondsSinceEpoch(0);
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  Future<void> approveApplication(
    BuildContext context,
    String applicationId,
    Map<String, dynamic> data,
  ) async {
    final uid = data['uid']?.toString().trim() ?? '';
    final phone =
        data['phone']?.toString() ??
        data['mobile']?.toString() ??
        data['mobileNumber']?.toString() ??
        '';

    if (uid.isEmpty && phone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Application में UID या mobile number नहीं है।'),
        ),
      );
      return;
    }

    try {
      final partnerId = uid.isNotEmpty ? uid : applicationId;

      final partnerData = <String, dynamic>{
        'name': data['name'] ?? data['fullName'] ?? 'Delivery Partner',
        'phone': phone,
        'mobile': data['mobile'] ?? phone,
        'mobileNumber': data['mobileNumber'] ?? phone,
        'vehicle': data['vehicle'] ?? '',
        'vehicleNumber': data['vehicleNumber'] ?? '',
        'area': data['area'] ?? '',
        'branchId': currentAdminBranchId,
        'branchName': currentAdminBranchName,
        'applicationId': applicationId,
        'authPhone': phone,
        'aadhaarLast4':
            (data['aadhaarNumber']
                        ?.toString()
                        .replaceAll(RegExp(r'\D'), '')
                        .length ??
                    0) >=
                4
            ? data['aadhaarNumber']
                  .toString()
                  .replaceAll(RegExp(r'\D'), '')
                  .substring(
                    data['aadhaarNumber']
                            .toString()
                            .replaceAll(RegExp(r'\D'), '')
                            .length -
                        4,
                  )
            : '',
        'active': true,
        'online': false,
        'availableForOrder': false,
        'approvedAt': FieldValue.serverTimestamp(),
        'createdAt': data['createdAt'] ?? FieldValue.serverTimestamp(),
      };

      await FirebaseFirestore.instance
          .collection('deliveryPartners')
          .doc(partnerId)
          .set(partnerData, SetOptions(merge: true));

      await FirebaseFirestore.instance
          .collection('deliveryPartnerApplications')
          .doc(applicationId)
          .set({
            'status': 'approved',
            'reviewedAt': FieldValue.serverTimestamp(),
            'reviewedBy': FirebaseAuth.instance.currentUser?.uid ?? '',
          }, SetOptions(merge: true));

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Delivery Partner approved successfully ✅'),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Approval failed: $e')));
      }
    }
  }

  Future<void> rejectApplication(
    BuildContext context,
    String applicationId,
  ) async {
    await FirebaseFirestore.instance
        .collection('deliveryPartnerApplications')
        .doc(applicationId)
        .set({
          'status': 'rejected',
          'reviewedAt': FieldValue.serverTimestamp(),
          'reviewedBy': FirebaseAuth.instance.currentUser?.uid ?? '',
        }, SetOptions(merge: true));

    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Application rejected')));
    }
  }

  Future<void> setActive(BuildContext context, String id, bool value) async {
    try {
      await FirebaseFirestore.instance
          .collection('deliveryPartners')
          .doc(id)
          .set({
            'active': value,
            if (!value) ...{
              'online': false,
              'availableForOrder': false,
              'adminOnlineEnabled': false,
              'requiresAdminReactivation': true,
            } else ...{
              'online': false,
              'availableForOrder': false,
              'adminOnlineEnabled': true,
              'requiresAdminReactivation': false,
            },
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(value ? 'Partner activated' : 'Partner deactivated'),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Status update failed: $e')));
      }
    }
  }

  String _maskAadhaar(String value) {
    final digits = value.replaceAll(RegExp(r'\D'), '');
    if (digits.length != 12) return 'Not valid';
    return 'XXXX XXXX ${digits.substring(8)}';
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          Container(
            color: Colors.white,
            child: const TabBar(
              tabs: [
                Tab(
                  icon: Icon(Icons.pending_actions_rounded),
                  text: 'Requests',
                ),
                Tab(icon: Icon(Icons.people_alt_rounded), text: 'Partners'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('deliveryPartnerApplications')
                      .where('status', isEqualTo: 'pending')
                      .snapshots(),
                  builder: (_, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(
                        child: CircularProgressIndicator(color: orange),
                      );
                    }

                    if (snapshot.hasError) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text(
                            'Registration requests load नहीं हुए.\n${snapshot.error}',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      );
                    }

                    final docs = snapshot.data?.docs ?? [];

                    if (docs.isEmpty) {
                      return const Center(
                        child: Text(
                          'कोई pending registration नहीं है।',
                          textAlign: TextAlign.center,
                        ),
                      );
                    }

                    return ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: docs.length,
                      itemBuilder: (_, index) {
                        final doc = docs[index];
                        final data = doc.data() as Map<String, dynamic>;

                        final name =
                            data['name']?.toString() ??
                            data['fullName']?.toString() ??
                            'Delivery Partner';

                        final phone =
                            data['phone']?.toString() ??
                            data['mobile']?.toString() ??
                            data['mobileNumber']?.toString() ??
                            '';

                        return Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(.035),
                                blurRadius: 12,
                              ),
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const CircleAvatar(
                                    backgroundColor: lightOrange,
                                    child: Icon(
                                      Icons.delivery_dining_rounded,
                                      color: orange,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      name,
                                      style: const TextStyle(
                                        fontSize: 17,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Text(
                                phone.isEmpty ? 'Mobile not provided' : phone,
                                style: const TextStyle(color: grey),
                              ),
                              if (data['vehicle'] != null)
                                Text(
                                  'Vehicle: ${data['vehicle']}',
                                  style: const TextStyle(color: grey),
                                ),
                              if (data['vehicleNumber'] != null)
                                Text(
                                  'Vehicle No.: ${data['vehicleNumber']}',
                                  style: const TextStyle(color: grey),
                                ),
                              if (data['area'] != null)
                                Text(
                                  'Area: ${data['area']}',
                                  style: const TextStyle(color: grey),
                                ),
                              if (data['aadhaarNumber'] != null)
                                Text(
                                  'Aadhaar: ${_maskAadhaar(data['aadhaarNumber'].toString())}',
                                  style: const TextStyle(color: grey),
                                ),
                              if ((data['aadhaarPhotoBase64']
                                      ?.toString()
                                      .isNotEmpty ??
                                  false))
                                Padding(
                                  padding: const EdgeInsets.only(top: 10),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(14),
                                    child: Image.memory(
                                      base64Decode(
                                        data['aadhaarPhotoBase64'].toString(),
                                      ),
                                      height: 150,
                                      width: double.infinity,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) =>
                                          const SizedBox.shrink(),
                                    ),
                                  ),
                                ),
                              const SizedBox(height: 14),
                              Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: () =>
                                          rejectApplication(context, doc.id),
                                      icon: const Icon(
                                        Icons.close_rounded,
                                        color: Colors.red,
                                      ),
                                      label: const Text('Reject'),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: ElevatedButton.icon(
                                      onPressed: () => approveApplication(
                                        context,
                                        doc.id,
                                        data,
                                      ),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: orange,
                                        foregroundColor: Colors.white,
                                      ),
                                      icon: const Icon(Icons.check_rounded),
                                      label: const Text('Approve'),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
                StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('deliveryPartners')
                      .where('branchId', isEqualTo: currentAdminBranchId)
                      .snapshots(),
                  builder: (_, snapshot) {
                    if (!snapshot.hasData) {
                      return const Center(
                        child: CircularProgressIndicator(color: orange),
                      );
                    }

                    final docs = snapshot.data!.docs.toList();
                    docs.sort((a, b) {
                      final ad = a.data() as Map<String, dynamic>;
                      final bd = b.data() as Map<String, dynamic>;
                      return _time(
                        bd['lastAssignedAt'] ??
                            bd['approvedAt'] ??
                            bd['createdAt'],
                      ).compareTo(
                        _time(
                          ad['lastAssignedAt'] ??
                              ad['approvedAt'] ??
                              ad['createdAt'],
                        ),
                      );
                    });

                    if (docs.isEmpty) {
                      return const Center(
                        child: Text('अभी कोई delivery partner नहीं है।'),
                      );
                    }

                    return ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: docs.length,
                      itemBuilder: (_, index) {
                        final doc = docs[index];
                        final data = doc.data() as Map<String, dynamic>;
                        final active = data['active'] != false;
                        final online = data['online'] == true;
                        final available = data['availableForOrder'] != false;

                        final name =
                            data['name']?.toString() ??
                            data['fullName']?.toString() ??
                            'Delivery Partner';

                        final phone =
                            data['phone']?.toString() ??
                            data['mobile']?.toString() ??
                            '';

                        return Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: online
                                  ? Colors.green.shade50
                                  : Colors.grey.shade100,
                              child: Icon(
                                Icons.delivery_dining_rounded,
                                color: online ? Colors.green : Colors.grey,
                              ),
                            ),
                            title: Text(
                              name,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            subtitle: Text(
                              '${phone.isEmpty ? 'No mobile' : phone}\n'
                              '${online ? 'ONLINE' : 'OFFLINE'} • '
                              '${available ? 'AVAILABLE' : 'BUSY'}',
                            ),
                            isThreeLine: true,
                            trailing: Switch(
                              value: active,
                              activeColor: orange,
                              onChanged: (value) =>
                                  setActive(context, doc.id, value),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// CUSTOMER COMPLAINTS / SUPPORT
// ============================================================

class ComplaintsPage extends StatelessWidget {
  const ComplaintsPage({super.key});

  Future<void> updateComplaint(
    BuildContext context,
    String id,
    String status,
  ) async {
    try {
      await FirebaseFirestore.instance
          .collection('customerComplaints')
          .doc(id)
          .set({
            'status': status,
            'updatedAt': FieldValue.serverTimestamp(),
            'updatedBy': FirebaseAuth.instance.currentUser?.uid ?? '',
          }, SetOptions(merge: true));

      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Complaint $status')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Complaint update failed: $e')));
      }
    }
  }

  String _name(Map<String, dynamic> data) {
    return data['customerName']?.toString() ??
        data['name']?.toString() ??
        'Customer';
  }

  String _message(Map<String, dynamic> data) {
    return data['message']?.toString() ??
        data['complaint']?.toString() ??
        data['description']?.toString() ??
        'No description';
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('customerComplaints')
          .snapshots(),
      builder: (_, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(color: orange));
        }

        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                'Complaints load नहीं हुईं.\n${snapshot.error}',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        final docs = snapshot.data?.docs ?? [];

        if (docs.isEmpty) {
          return const Center(
            child: Text(
              'अभी कोई customer complaint नहीं है।',
              textAlign: TextAlign.center,
            ),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: docs.length,
          itemBuilder: (_, index) {
            final doc = docs[index];
            final data = doc.data() as Map<String, dynamic>;

            final status = data['status']?.toString() ?? 'Pending';

            final orderId = data['orderId']?.toString() ?? '';

            return Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const CircleAvatar(
                        backgroundColor: Color(0xFFFFF4EC),
                        child: Icon(Icons.support_agent_rounded, color: orange),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _name(data),
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Chip(
                        label: Text(status),
                        backgroundColor: status == 'Resolved'
                            ? Colors.green.shade50
                            : status == 'In Progress'
                            ? Colors.orange.shade50
                            : Colors.red.shade50,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(_message(data), style: const TextStyle(fontSize: 15)),
                  if (orderId.isNotEmpty) ...[
                    const SizedBox(height: 7),
                    Text(
                      'Order: $orderId',
                      style: const TextStyle(color: grey),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: () =>
                            updateComplaint(context, doc.id, 'In Progress'),
                        child: const Text('In Progress'),
                      ),
                      ElevatedButton(
                        onPressed: () =>
                            updateComplaint(context, doc.id, 'Resolved'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('Resolve'),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

// ============================================================
// COMMON INPUT DECORATION
// ============================================================

InputDecoration inputDecoration(String label, IconData icon, {Widget? suffix}) {
  return InputDecoration(
    labelText: label,
    prefixIcon: Icon(icon),
    suffixIcon: suffix,
    filled: true,
    fillColor: Colors.white,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: BorderSide(color: Colors.grey.shade200),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: BorderSide(color: Colors.grey.shade200),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: const BorderSide(color: orange, width: 2),
    ),
  );
}

// ============================================================
// DELIVERY PARTNER COMPLAINTS + ASSETS
// ============================================================

class DeliveryPartnerComplaintsPage extends StatelessWidget {
  const DeliveryPartnerComplaintsPage({super.key});

  Future<void> _update(BuildContext context, String id, String status) async {
    await FirebaseFirestore.instance
        .collection('deliveryPartnerComplaints')
        .doc(id)
        .set({
          'status': status,
          'updatedAt': FieldValue.serverTimestamp(),
          'updatedBy': FirebaseAuth.instance.currentUser?.uid ?? '',
        }, SetOptions(merge: true));
    if (context.mounted)
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Complaint $status')));
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('deliveryPartnerComplaints')
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError)
          return Center(
            child: Text(
              'Delivery partner complaints load नहीं हुईं.\n${snapshot.error}',
              textAlign: TextAlign.center,
            ),
          );
        if (!snapshot.hasData)
          return const Center(child: CircularProgressIndicator(color: orange));
        final docs = [...snapshot.data!.docs];
        docs.sort(
          (a, b) =>
              ((b.data()['createdAt'] as Timestamp?)?.millisecondsSinceEpoch ??
                      0)
                  .compareTo(
                    (a.data()['createdAt'] as Timestamp?)
                            ?.millisecondsSinceEpoch ??
                        0,
                  ),
        );
        if (docs.isEmpty)
          return const Center(
            child: Text('अभी कोई delivery partner complaint नहीं है.'),
          );
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: docs.length,
          itemBuilder: (_, i) {
            final d = docs[i];
            final data = d.data();
            final status = data['status']?.toString() ?? 'Pending';
            final attachment = data['attachmentBase64']?.toString() ?? '';
            return Card(
              margin: const EdgeInsets.only(bottom: 12),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const CircleAvatar(
                          child: Icon(Icons.delivery_dining_rounded),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            data['partnerName']?.toString() ??
                                'Delivery Partner',
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                              fontSize: 17,
                            ),
                          ),
                        ),
                        Chip(label: Text(status)),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      data['subject']?.toString() ?? 'Complaint',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 5),
                    Text(data['description']?.toString() ?? ''),
                    if ((data['category']?.toString() ?? '').isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 5),
                        child: Text('Category: ${data['category']}'),
                      ),
                    if ((data['orderId']?.toString() ?? '').isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 5),
                        child: Text('Order: ${data['orderId']}'),
                      ),
                    if (attachment.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: Image.memory(
                          base64Decode(attachment),
                          height: 180,
                          width: double.infinity,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton(
                          onPressed: () =>
                              _update(context, d.id, 'In Progress'),
                          child: const Text('In Progress'),
                        ),
                        FilledButton(
                          onPressed: () => _update(context, d.id, 'Resolved'),
                          child: const Text('Resolve'),
                        ),
                        OutlinedButton(
                          onPressed: () => _update(context, d.id, 'Rejected'),
                          child: const Text('Reject'),
                        ),
                      ],
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
}

class DeliveryAssetsAdminPage extends StatefulWidget {
  const DeliveryAssetsAdminPage({super.key});
  @override
  State<DeliveryAssetsAdminPage> createState() =>
      _DeliveryAssetsAdminPageState();
}

class _DeliveryAssetsAdminPageState extends State<DeliveryAssetsAdminPage> {
  static const defaults = [
    {'name': 'FlashCart Delivery T-Shirt', 'price': 199, 'icon': '👕'},
    {'name': 'Delivery Cap', 'price': 99, 'icon': '🧢'},
    {'name': 'Rain Cover', 'price': 149, 'icon': '🌧️'},
    {'name': 'ID Card Holder', 'price': 69, 'icon': '🪪'},
    {'name': 'Reflective Safety Vest', 'price': 179, 'icon': '🦺'},
    {'name': 'Mobile Holder', 'price': 199, 'icon': '📱'},
  ];

  Future<void> seedDefaults() async {
    final batch = FirebaseFirestore.instance.batch();
    for (final item in defaults) {
      final ref = FirebaseFirestore.instance.collection('deliveryAssets').doc();
      batch.set(ref, {
        ...item,
        'available': true,
        'updatedAt': FieldValue.serverTimestamp(),
        'createdAt': FieldValue.serverTimestamp(),
      });
    }
    await batch.commit();
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Default delivery assets added ✓')),
      );
  }

  Future<void> addAsset() async {
    final name = TextEditingController();
    final price = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Add Delivery Asset'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Asset name'),
            ),
            TextField(
              controller: price,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Price ₹69–₹199'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    final p = int.tryParse(price.text.trim()) ?? 0;
    if (ok == true && name.text.trim().isNotEmpty && p >= 69 && p <= 199) {
      await FirebaseFirestore.instance.collection('deliveryAssets').add({
        'name': name.text.trim(),
        'price': p,
        'icon': '📦',
        'available': true,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
    name.dispose();
    price.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Delivery Partner Assets',
                  style: TextStyle(fontSize: 23, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 6),
                const Text('Low-cost useful items only. Price range ₹69–₹199.'),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: seedDefaults,
                      icon: const Icon(Icons.auto_awesome),
                      label: const Text('Add Defaults'),
                    ),
                    OutlinedButton.icon(
                      onPressed: addAsset,
                      icon: const Icon(Icons.add),
                      label: const Text('Add Asset'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection('deliveryAssets')
              .snapshots(),
          builder: (_, s) {
            if (!s.hasData)
              return const Center(
                child: CircularProgressIndicator(color: orange),
              );
            final docs = s.data!.docs;
            if (docs.isEmpty)
              return const Padding(
                padding: EdgeInsets.all(20),
                child: Text('Add Defaults दबाकर assets डालें.'),
              );
            return Column(
              children: docs.map((d) {
                final x = d.data();
                return Card(
                  child: ListTile(
                    leading: Text(
                      x['icon']?.toString() ?? '📦',
                      style: const TextStyle(fontSize: 28),
                    ),
                    title: Text(
                      x['name']?.toString() ?? 'Asset',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    subtitle: Text('₹${x['price'] ?? 0}'),
                    trailing: Switch(
                      value: x['available'] != false,
                      onChanged: (v) => d.reference.set({
                        'available': v,
                        'updatedAt': FieldValue.serverTimestamp(),
                      }, SetOptions(merge: true)),
                    ),
                  ),
                );
              }).toList(),
            );
          },
        ),
        const SizedBox(height: 20),
        const Text(
          'Asset Requests',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 8),
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection('deliveryAssetRequests')
              .snapshots(),
          builder: (_, s) {
            if (!s.hasData) return const SizedBox.shrink();
            return Column(
              children: s.data!.docs.map((d) {
                final x = d.data();
                final status =
                    [
                      'Pending',
                      'Approved',
                      'Rejected',
                      'Delivered',
                    ].contains(x['status'])
                    ? x['status'].toString()
                    : 'Pending';
                return Card(
                  child: ListTile(
                    title: Text(x['assetName']?.toString() ?? 'Asset'),
                    subtitle: Text(
                      '${x['partnerName'] ?? 'Partner'} • ₹${x['price'] ?? 0}',
                    ),
                    trailing: DropdownButton<String>(
                      value: status,
                      items:
                          const ['Pending', 'Approved', 'Rejected', 'Delivered']
                              .map(
                                (v) => DropdownMenuItem<String>(
                                  value: v,
                                  child: Text(v),
                                ),
                              )
                              .toList(),
                      onChanged: (v) {
                        if (v != null) {
                          d.reference.set({
                            'status': v,
                            'updatedAt': FieldValue.serverTimestamp(),
                          }, SetOptions(merge: true));
                        }
                      },
                    ),
                  ),
                );
              }).toList(),
            );
          },
        ),
      ],
    );
  }
}

// ============================================================
// TRAINING VIDEO MANAGEMENT
// ============================================================

class TrainingVideosAdminPage extends StatefulWidget {
  const TrainingVideosAdminPage({super.key});

  @override
  State<TrainingVideosAdminPage> createState() =>
      _TrainingVideosAdminPageState();
}

class _TrainingVideosAdminPageState extends State<TrainingVideosAdminPage> {
  bool saving = false;

  Future<void> _addVideo() async {
    final title = TextEditingController();
    final description = TextEditingController();
    final duration = TextEditingController();
    final sortOrder = TextEditingController(text: '1');
    final url = TextEditingController();
    bool published = true;

    final selected = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setLocalState) => AlertDialog(
          title: const Text(
            'Add Training Video Link',
            style: TextStyle(fontWeight: FontWeight.w900),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: title,
                  decoration: const InputDecoration(labelText: 'Video title'),
                ),
                TextField(
                  controller: description,
                  decoration: const InputDecoration(labelText: 'Description'),
                ),
                TextField(
                  controller: url,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'YouTube / Video URL',
                  ),
                ),
                TextField(
                  controller: duration,
                  decoration: const InputDecoration(
                    labelText: 'Duration (e.g. 5:30)',
                  ),
                ),
                TextField(
                  controller: sortOrder,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Display order'),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Publish now'),
                  value: published,
                  onChanged: (v) => setLocalState(() => published = v),
                ),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Free mode: video file Firebase Storage में upload नहीं होगा. केवल video link save होगा.',
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: title.text.trim().isEmpty || url.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(dialogContext, true),
              child: const Text('Save Video'),
            ),
          ],
        ),
      ),
    );

    if (selected != true) {
      title.dispose();
      description.dispose();
      duration.dispose();
      sortOrder.dispose();
      url.dispose();
      return;
    }

    final link = url.text.trim();
    final uri = Uri.tryParse(link);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Valid YouTube/video URL डालें.')),
        );
      title.dispose();
      description.dispose();
      duration.dispose();
      sortOrder.dispose();
      url.dispose();
      return;
    }

    setState(() => saving = true);
    try {
      await FirebaseFirestore.instance.collection('deliveryTrainingVideos').add(
        {
          'title': title.text.trim(),
          'description': description.text.trim(),
          'videoUrl': link,
          'thumbnailUrl': '',
          'duration': duration.text.trim(),
          'sortOrder': int.tryParse(sortOrder.text.trim()) ?? 1,
          'published': published,
          'source': 'external_link',
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
          'createdBy': FirebaseAuth.instance.currentUser?.uid ?? '',
        },
      );
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Training video link saved ✓')),
        );
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Save failed: $e')));
    } finally {
      title.dispose();
      description.dispose();
      duration.dispose();
      sortOrder.dispose();
      url.dispose();
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _toggle(String id, bool value) async {
    await FirebaseFirestore.instance
        .collection('deliveryTrainingVideos')
        .doc(id)
        .set({
          'published': value,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
  }

  Future<void> _delete(String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete training video?'),
        content: const Text('Video link record हट जाएगा।'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true)
      await FirebaseFirestore.instance
          .collection('deliveryTrainingVideos')
          .doc(id)
          .delete();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7FB),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: saving ? null : _addVideo,
        backgroundColor: orange,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.link_rounded),
        label: Text(saving ? 'Saving...' : 'Add Video Link'),
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('deliveryTrainingVideos')
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError)
            return Center(
              child: Text(
                'Videos load नहीं हुए.\n${snapshot.error}',
                textAlign: TextAlign.center,
              ),
            );
          if (!snapshot.hasData)
            return const Center(
              child: CircularProgressIndicator(color: orange),
            );
          final docs = [...snapshot.data!.docs];
          docs.sort(
            (a, b) => ((a.data()['sortOrder'] ?? 0) as num).compareTo(
              (b.data()['sortOrder'] ?? 0) as num,
            ),
          );
          if (docs.isEmpty)
            return const Center(
              child: Text(
                'अभी कोई training video नहीं है।\nनीचे Add Video Link दबाएँ.',
                textAlign: TextAlign.center,
              ),
            );
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
            itemCount: docs.length,
            itemBuilder: (_, i) {
              final d = docs[i];
              final data = d.data();
              final url = data['videoUrl']?.toString() ?? '';
              final published = data['published'] == true;
              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: published
                        ? Colors.green.shade50
                        : Colors.grey.shade100,
                    child: Icon(
                      Icons.play_arrow_rounded,
                      color: published ? Colors.green : Colors.grey,
                    ),
                  ),
                  title: Text(
                    data['title']?.toString() ?? 'Training Video',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: Text(
                    '${data['description']?.toString() ?? ''}\n${published ? 'Published' : 'Hidden'}',
                  ),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) async {
                      if (v == 'open')
                        await launchUrl(
                          Uri.parse(url),
                          mode: LaunchMode.externalApplication,
                        );
                      if (v == 'toggle') await _toggle(d.id, !published);
                      if (v == 'delete') await _delete(d.id);
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'open',
                        child: Text('Open Video'),
                      ),
                      PopupMenuItem(
                        value: 'toggle',
                        child: Text(published ? 'Unpublish' : 'Publish'),
                      ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete'),
                      ),
                    ],
                  ),
                  isThreeLine: true,
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
// EMERGENCY CENTER
// ============================================================

class EmergencyCenterPage extends StatelessWidget {
  const EmergencyCenterPage({super.key});

  Future<void> _call(BuildContext context, String number, String label) async {
    final uri = Uri(scheme: 'tel', path: number);
    final ok = await launchUrl(uri);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$label call open नहीं हो सका.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        const Text(
          'Emergency Center',
          style: TextStyle(fontSize: 25, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 8),
        const Text(
          'Emergency situation में तुरंत call करने के लिए shortcuts.',
          style: TextStyle(color: grey),
        ),
        const SizedBox(height: 20),
        _emergencyButton(
          context,
          Icons.local_hospital_rounded,
          'Call Ambulance',
          '108',
          () => _call(context, '108', 'Ambulance'),
        ),
        const SizedBox(height: 12),
        _emergencyButton(
          context,
          Icons.local_police_rounded,
          'Call Police / Emergency',
          '112',
          () => _call(context, '112', 'Police'),
        ),
        const SizedBox(height: 20),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: const [
                Icon(Icons.info_outline_rounded, color: orange),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Emergency shortcuts phone dialer खोलते हैं। Call करने से पहले number और situation verify करें.',
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _emergencyButton(
    BuildContext context,
    IconData icon,
    String title,
    String number,
    VoidCallback onTap,
  ) {
    return SizedBox(
      height: 72,
      child: FilledButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 30),
        label: Expanded(
          child: Text(
            '$title  •  $number',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
          ),
        ),
        style: FilledButton.styleFrom(
          backgroundColor: title.contains('Ambulance')
              ? Colors.red
              : Colors.blue,
        ),
      ),
    );
  }
}

// ============================================================
// REPORTS & ANALYTICS
// ============================================================

class ReportsAnalyticsPage extends StatelessWidget {
  const ReportsAnalyticsPage({super.key});

  double _num(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String)
      return double.tryParse(value.replaceAll(RegExp(r'[^0-9.\\-]'), '')) ?? 0;
    return 0;
  }

  double _orderTotal(Map<String, dynamic> d) {
    for (final k in const [
      'total',
      'totalAmount',
      'grandTotal',
      'orderTotal',
      'payableAmount',
      'amount',
    ]) {
      final v = _num(d[k]);
      if (v > 0) return v;
    }
    final items = d['items'] ?? d['orderItems'] ?? d['products'];
    if (items is List) {
      double total = 0;
      for (final item in items) {
        if (item is Map) {
          final p = _num(
            item['sellingPrice'] ?? item['price'] ?? item['unitPrice'],
          );
          final q = _num(item['quantity'] ?? item['qty'] ?? 1);
          total += p * (q <= 0 ? 1 : q);
        }
      }
      return total;
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('orders')
          .where('branchId', isEqualTo: currentAdminBranchId)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError)
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                'Reports load नहीं हुए.\n${snapshot.error}',
                textAlign: TextAlign.center,
              ),
            ),
          );
        if (!snapshot.hasData)
          return const Center(child: CircularProgressIndicator(color: orange));

        final docs = snapshot.data!.docs;
        var delivered = 0;
        var pending = 0;
        var cancelled = 0;
        double sales = 0;
        for (final doc in docs) {
          final status = (doc.data()['status'] ?? '').toString().toLowerCase();
          if (status == 'delivered') {
            delivered++;
            sales += _orderTotal(doc.data());
          } else if (status.contains('cancel')) {
            cancelled++;
          } else {
            pending++;
          }
        }

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Reports & Analytics',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 6),
            const Text(
              'Orders, delivery और sales का live summary.',
              style: TextStyle(color: grey),
            ),
            const SizedBox(height: 18),
            _metricGrid(context, [
              _Metric(
                'Total Orders',
                '${docs.length}',
                Icons.shopping_bag_rounded,
              ),
              _Metric('Delivered', '$delivered', Icons.check_circle_rounded),
              _Metric('Pending', '$pending', Icons.pending_actions_rounded),
              _Metric('Cancelled', '$cancelled', Icons.cancel_rounded),
            ]),
            const SizedBox(height: 14),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Row(
                  children: [
                    const CircleAvatar(
                      backgroundColor: lightOrange,
                      child: Icon(Icons.currency_rupee_rounded, color: orange),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Delivered sales',
                            style: TextStyle(color: grey),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '₹${sales.toStringAsFixed(2)}',
                            style: const TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Operations checklist',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 10),
                    _checkRow('New orders auto-assignment', true),
                    _checkRow('Partner auto-offline after delivery', true),
                    _checkRow('Partner complaints', true),
                    _checkRow('Training video links', true),
                    _checkRow('Delivery assets', true),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _metricGrid(BuildContext context, List<_Metric> metrics) {
    final width = MediaQuery.sizeOf(context).width;
    final columns = width >= 900
        ? 4
        : width >= 600
        ? 2
        : 2;
    final itemWidth = (width - 32 - ((columns - 1) * 10)) / columns;
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: metrics
          .map(
            (m) => SizedBox(
              width: itemWidth.clamp(145, 320),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(15),
                  child: Row(
                    children: [
                      CircleAvatar(
                        backgroundColor: lightOrange,
                        child: Icon(m.icon, color: orange),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          m.label,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      Text(
                        m.value,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          )
          .toList(),
    );
  }

  Widget _checkRow(String label, bool ok) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: [
        Icon(
          ok ? Icons.check_circle : Icons.error,
          color: ok ? Colors.green : Colors.red,
          size: 20,
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(label)),
      ],
    ),
  );
}

class _Metric {
  final String label;
  final String value;
  final IconData icon;
  const _Metric(this.label, this.value, this.icon);
}

// ============================================================
// ADMIN NOTIFICATIONS / ANNOUNCEMENTS
// ============================================================

class AdminNotificationsPage extends StatefulWidget {
  const AdminNotificationsPage({super.key});
  @override
  State<AdminNotificationsPage> createState() => _AdminNotificationsPageState();
}

class _AdminNotificationsPageState extends State<AdminNotificationsPage> {
  Future<void> _add() async {
    final title = TextEditingController();
    final message = TextEditingController();
    String audience = 'all';
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text(
          'New Announcement',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: title,
                decoration: const InputDecoration(labelText: 'Title'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: message,
                maxLines: 4,
                decoration: const InputDecoration(labelText: 'Message'),
              ),
              const SizedBox(height: 10),
              StatefulBuilder(
                builder: (context, setLocal) => DropdownButtonFormField<String>(
                  value: audience,
                  decoration: const InputDecoration(labelText: 'Audience'),
                  items: const [
                    DropdownMenuItem(value: 'all', child: Text('Everyone')),
                    DropdownMenuItem(
                      value: 'customers',
                      child: Text('Customers'),
                    ),
                    DropdownMenuItem(
                      value: 'partners',
                      child: Text('Delivery Partners'),
                    ),
                  ],
                  onChanged: (v) {
                    if (v != null) {
                      audience = v;
                      setLocal(() {});
                    }
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Publish'),
          ),
        ],
      ),
    );
    if (ok == true &&
        title.text.trim().isNotEmpty &&
        message.text.trim().isNotEmpty) {
      await FirebaseFirestore.instance.collection('adminNotifications').add({
        'title': title.text.trim(),
        'message': message.text.trim(),
        'published': true,
        'audience': audience,
        'createdAt': FieldValue.serverTimestamp(),
        'createdBy': FirebaseAuth.instance.currentUser?.uid ?? '',
      });
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Announcement published ✓')),
        );
    }
    title.dispose();
    message.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        backgroundColor: orange,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_alert_rounded),
        label: const Text('New Announcement'),
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('adminNotifications')
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError)
            return Center(
              child: Text(
                'Notifications load नहीं हुईं.\n${snapshot.error}',
                textAlign: TextAlign.center,
              ),
            );
          if (!snapshot.hasData)
            return const Center(
              child: CircularProgressIndicator(color: orange),
            );
          final docs = [...snapshot.data!.docs];
          docs.sort(
            (a, b) =>
                ((b.data()['createdAt'] as Timestamp?)
                            ?.millisecondsSinceEpoch ??
                        0)
                    .compareTo(
                      (a.data()['createdAt'] as Timestamp?)
                              ?.millisecondsSinceEpoch ??
                          0,
                    ),
          );
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
            itemCount: docs.length + 1,
            itemBuilder: (_, i) {
              if (i == 0)
                return const Padding(
                  padding: EdgeInsets.only(bottom: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Notifications',
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      SizedBox(height: 5),
                      Text(
                        'Customers/partners के लिए announcements यहाँ manage करें.',
                        style: TextStyle(color: grey),
                      ),
                    ],
                  ),
                );
              final d = docs[i - 1];
              final data = d.data();
              return Card(
                margin: const EdgeInsets.only(bottom: 10),
                child: ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: lightOrange,
                    child: Icon(
                      Icons.notifications_active_rounded,
                      color: orange,
                    ),
                  ),
                  title: Text(
                    data['title']?.toString() ?? 'Announcement',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: Text(data['message']?.toString() ?? ''),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: () => FirebaseFirestore.instance
                        .collection('adminNotifications')
                        .doc(d.id)
                        .delete(),
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

class DeliveryIncentivesPage extends StatefulWidget {
  const DeliveryIncentivesPage({super.key});

  @override
  State<DeliveryIncentivesPage> createState() => _DeliveryIncentivesPageState();
}

class _DeliveryIncentivesPageState extends State<DeliveryIncentivesPage> {
  String dateKey = adminIncentiveDateKey();

  Future<void> _editPlan({
    String? existingId,
    Map<String, dynamic>? existing,
  }) async {
    final dateController = TextEditingController(
      text: existing?['dateKey']?.toString() ?? dateKey,
    );
    final titleController = TextEditingController(
      text: existing?['title']?.toString() ?? '',
    );

    final rawTargets = existing?['targets'];
    final rows = <Map<String, TextEditingController>>[];
    if (rawTargets is List && rawTargets.isNotEmpty) {
      for (final raw in rawTargets) {
        if (raw is Map) {
          rows.add({
            'orders': TextEditingController(
              text: raw['orderCount']?.toString() ?? '',
            ),
            'amount': TextEditingController(
              text: raw['amount']?.toString() ?? '',
            ),
          });
        }
      }
    }
    if (rows.isEmpty) {
      rows.add({
        'orders': TextEditingController(text: '5'),
        'amount': TextEditingController(text: '100'),
      });
    }

    bool active = existing?['active'] != false;

    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setLocal) {
          return AlertDialog(
            title: Text(
              existingId == null ? 'Create Daily Incentive' : 'Edit Incentive',
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
            content: SizedBox(
              width: 500,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: dateController,
                      decoration: const InputDecoration(
                        labelText: 'Date (YYYY-MM-DD)',
                        prefixIcon: Icon(Icons.calendar_today_rounded),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: titleController,
                      decoration: const InputDecoration(
                        labelText: 'Festival / Incentive title',
                        prefixIcon: Icon(Icons.emoji_events_rounded),
                      ),
                    ),
                    const SizedBox(height: 14),
                    ...List.generate(rows.length, (i) {
                      final row = rows[i];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: row['orders'],
                                keyboardType: TextInputType.number,
                                decoration: InputDecoration(
                                  labelText: 'Target orders ${i + 1}',
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: row['amount'],
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: 'Incentive ₹',
                                ),
                              ),
                            ),
                            IconButton(
                              onPressed: rows.length == 1
                                  ? null
                                  : () => setLocal(() => rows.removeAt(i)),
                              icon: const Icon(
                                Icons.delete_outline,
                                color: red,
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: () => setLocal(
                          () => rows.add({
                            'orders': TextEditingController(),
                            'amount': TextEditingController(),
                          }),
                        ),
                        icon: const Icon(Icons.add),
                        label: const Text('Add target'),
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: active,
                      title: const Text('Active today'),
                      onChanged: (v) => setLocal(() => active = v),
                    ),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Example: 5 orders ₹100, 10 orders ₹250. '
                        'At 10 completed orders total incentive becomes ₹250.',
                        style: TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );

    if (ok != true) {
      dateController.dispose();
      titleController.dispose();
      for (final row in rows) {
        row['orders']!.dispose();
        row['amount']!.dispose();
      }
      return;
    }

    final cleanDate = dateController.text.trim();
    final parsedDate = RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(cleanDate);
    final targets = <Map<String, dynamic>>[];

    for (final row in rows) {
      final orders = int.tryParse(row['orders']!.text.trim()) ?? 0;
      final amount = double.tryParse(row['amount']!.text.trim()) ?? 0;
      if (orders > 0 && amount >= 0) {
        targets.add({'orderCount': orders, 'amount': amount});
      }
    }

    targets.sort(
      (a, b) => (a['orderCount'] as int).compareTo(b['orderCount'] as int),
    );

    if (!parsedDate || targets.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Date और कम से कम एक valid target भरें.'),
            backgroundColor: red,
          ),
        );
      }
    } else {
      await FirebaseFirestore.instance
          .collection('incentivePlans')
          .doc(cleanDate)
          .set({
            'dateKey': cleanDate,
            'title': titleController.text.trim().isEmpty
                ? 'Daily Delivery Incentive'
                : titleController.text.trim(),
            'targets': targets,
            'active': active,
            'updatedAt': FieldValue.serverTimestamp(),
            'updatedBy': FirebaseAuth.instance.currentUser?.uid ?? '',
          }, SetOptions(merge: true));

      if (mounted) {
        setState(() => dateKey = cleanDate);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Daily incentive saved ✓')),
        );
      }
    }

    dateController.dispose();
    titleController.dispose();
    for (final row in rows) {
      row['orders']!.dispose();
      row['amount']!.dispose();
    }
  }

  Future<void> _deletePlan(String id) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete incentive?'),
        content: Text('आज के target plan "$id" delete करना है?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            style: FilledButton.styleFrom(backgroundColor: red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (yes == true) {
      await FirebaseFirestore.instance
          .collection('incentivePlans')
          .doc(id)
          .delete();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editPlan(),
        backgroundColor: orange,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Daily Incentive'),
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('incentivePlans')
            .orderBy('dateKey', descending: true)
            .limit(60)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Text('Incentives load नहीं हुए.\n${snapshot.error}'),
            );
          }
          if (!snapshot.hasData) {
            return const Center(
              child: CircularProgressIndicator(color: orange),
            );
          }

          final docs = snapshot.data!.docs;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
            children: [
              const Text(
                'Delivery Incentives',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 6),
              const Text(
                'हर दिन अलग target/amount रखें. Festival days पर higher incentive भी सेट कर सकते हैं.',
                style: TextStyle(color: grey),
              ),
              const SizedBox(height: 16),
              if (docs.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(18),
                    child: Text('अभी कोई daily incentive plan नहीं है.'),
                  ),
                ),
              ...docs.map((doc) {
                final d = doc.data();
                final targets = d['targets'] is List
                    ? List<dynamic>.from(d['targets'] as List)
                    : <dynamic>[];
                return Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.emoji_events_rounded,
                              color: yellow,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '${d['dateKey'] ?? doc.id} • ${d['title'] ?? 'Daily Incentive'}',
                                style: const TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                            Switch(
                              value: d['active'] == true,
                              onChanged: (v) =>
                                  doc.reference.update({'active': v}),
                            ),
                            IconButton(
                              onPressed: () =>
                                  _editPlan(existingId: doc.id, existing: d),
                              icon: const Icon(Icons.edit_outlined),
                            ),
                            IconButton(
                              onPressed: () => _deletePlan(doc.id),
                              icon: const Icon(
                                Icons.delete_outline,
                                color: red,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: targets.whereType<Map>().map((raw) {
                            final count = raw['orderCount'] ?? 0;
                            final amount = raw['amount'] ?? 0;
                            return Chip(
                              label: Text('$count orders → ₹$amount'),
                              avatar: const Icon(Icons.flag_rounded, size: 17),
                            );
                          }).toList(),
                        ),
                      ],
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
// OFFERS & COUPONS
// ============================================================

class OffersCouponsPage extends StatefulWidget {
  const OffersCouponsPage({super.key});
  @override
  State<OffersCouponsPage> createState() => _OffersCouponsPageState();
}

class _OffersCouponsPageState extends State<OffersCouponsPage> {
  Future<void> _addOffer() async {
    final name = TextEditingController();
    final code = TextEditingController();
    final discount = TextEditingController();
    final minOrder = TextEditingController(text: '0');
    bool active = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setLocal) => AlertDialog(
          title: const Text(
            'Add Offer / Coupon',
            style: TextStyle(fontWeight: FontWeight.w900),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Offer name'),
                ),
                TextField(
                  controller: code,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(labelText: 'Coupon code'),
                ),
                TextField(
                  controller: discount,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Discount %'),
                ),
                TextField(
                  controller: minOrder,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Minimum order ₹',
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: active,
                  title: const Text('Active'),
                  onChanged: (v) => setLocal(() => active = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    final discountValue = int.tryParse(discount.text.trim()) ?? -1;
    if (ok == true &&
        name.text.trim().isNotEmpty &&
        code.text.trim().isNotEmpty &&
        discountValue >= 0 &&
        discountValue <= 100) {
      await FirebaseFirestore.instance.collection('offers').add({
        'name': name.text.trim(),
        'code': code.text.trim().toUpperCase(),
        'discountPercent': discountValue,
        'minOrder': int.tryParse(minOrder.text.trim()) ?? 0,
        'active': active,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Offer saved ✓')));
    }
    name.dispose();
    code.dispose();
    discount.dispose();
    minOrder.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addOffer,
        backgroundColor: orange,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Add Offer'),
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance.collection('offers').snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError)
            return Center(
              child: Text(
                'Offers load नहीं हुए.\n${snapshot.error}',
                textAlign: TextAlign.center,
              ),
            );
          if (!snapshot.hasData)
            return const Center(
              child: CircularProgressIndicator(color: orange),
            );
          final docs = snapshot.data!.docs;
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
            itemCount: docs.length + 1,
            itemBuilder: (_, i) {
              if (i == 0)
                return const Padding(
                  padding: EdgeInsets.only(bottom: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Offers & Coupons',
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      SizedBox(height: 5),
                      Text(
                        'Discount offers create और active/inactive manage करें.',
                        style: TextStyle(color: grey),
                      ),
                    ],
                  ),
                );
              final d = docs[i - 1];
              final data = d.data();
              final active = data['active'] == true;
              return Card(
                margin: const EdgeInsets.only(bottom: 10),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: active
                        ? Colors.green.shade50
                        : Colors.grey.shade100,
                    child: Icon(
                      Icons.local_offer_rounded,
                      color: active ? Colors.green : grey,
                    ),
                  ),
                  title: Text(
                    data['name']?.toString() ?? 'Offer',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: Text(
                    '${data['code'] ?? ''} • ${data['discountPercent'] ?? 0}% off • Min ₹${data['minOrder'] ?? 0}',
                  ),
                  trailing: Switch(
                    value: active,
                    onChanged: (v) => FirebaseFirestore.instance
                        .collection('offers')
                        .doc(d.id)
                        .set({
                          'active': v,
                          'updatedAt': FieldValue.serverTimestamp(),
                        }, SetOptions(merge: true)),
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
// APP SETTINGS
// ============================================================

class AdminSettingsPage extends StatefulWidget {
  const AdminSettingsPage({super.key});
  @override
  State<AdminSettingsPage> createState() => _AdminSettingsPageState();
}

class _AdminSettingsPageState extends State<AdminSettingsPage> {
  final minOrder = TextEditingController();
  final deliveryFee = TextEditingController();
  final supportPhone = TextEditingController();
  bool maintenance = false;
  bool loaded = false;

  Future<void> _load() async {
    final doc = await FirebaseFirestore.instance
        .collection('appSettings')
        .doc('general')
        .get();
    final d = doc.data() ?? {};
    minOrder.text = (d['minOrder'] ?? 0).toString();
    deliveryFee.text = (d['deliveryFee'] ?? 0).toString();
    supportPhone.text = (d['supportPhone'] ?? '').toString();
    maintenance = d['maintenance'] == true;
    if (mounted) setState(() => loaded = true);
  }

  Future<void> _save() async {
    await FirebaseFirestore.instance
        .collection('appSettings')
        .doc('general')
        .set({
          'minOrder': double.tryParse(minOrder.text.trim()) ?? 0,
          'deliveryFee': double.tryParse(deliveryFee.text.trim()) ?? 0,
          'supportPhone': supportPhone.text.trim(),
          'maintenance': maintenance,
          'updatedAt': FieldValue.serverTimestamp(),
          'updatedBy': FirebaseAuth.instance.currentUser?.uid ?? '',
        }, SetOptions(merge: true));
    if (mounted)
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Settings saved ✓')));
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    minOrder.dispose();
    deliveryFee.dispose();
    supportPhone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!loaded)
      return const Center(child: CircularProgressIndicator(color: orange));
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'App Settings',
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 6),
        const Text(
          'Basic business settings. Customer app में use करने के लिए वही Firestore document पढ़ें.',
          style: TextStyle(color: grey),
        ),
        const SizedBox(height: 18),
        TextField(
          controller: minOrder,
          keyboardType: TextInputType.number,
          decoration: inputDecoration(
            'Minimum Order ₹',
            Icons.shopping_cart_checkout_rounded,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: deliveryFee,
          keyboardType: TextInputType.number,
          decoration: inputDecoration(
            'Delivery Fee ₹',
            Icons.delivery_dining_rounded,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: supportPhone,
          keyboardType: TextInputType.phone,
          decoration: inputDecoration('Support Phone', Icons.phone_rounded),
        ),
        const SizedBox(height: 8),
        Card(
          child: ListTile(
            leading: const Icon(Icons.email_outlined, color: orange),
            title: const Text(
              'Support Email',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            subtitle: const Text(flashCartSupportEmail),
            onTap: () {
              Clipboard.setData(
                const ClipboardData(text: flashCartSupportEmail),
              );
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Support email copied')),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text(
            'Maintenance mode',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: const Text(
            'Enable only when you intentionally want to pause ordering.',
          ),
          value: maintenance,
          onChanged: (v) => setState(() => maintenance = v),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 52,
          child: FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save_rounded),
            label: const Text('Save Settings'),
          ),
        ),
      ],
    );
  }
}

class AdminWeeklyEarningsPage extends StatelessWidget {
  const AdminWeeklyEarningsPage({super.key});
  @override
  Widget build(BuildContext context) {
    final branchId = currentAdminBranchId;
    if (branchId.isEmpty)
      return const Center(child: Text('आपकी branch assign नहीं है.'));
    final db = FirebaseFirestore.instance;
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: db
          .collection('orders')
          .where('branchId', isEqualTo: branchId)
          .snapshots(),
      builder: (context, os) {
        if (os.hasError)
          return Center(child: Text('Orders load error: ${os.error}'));
        if (!os.hasData)
          return const Center(child: CircularProgressIndicator());
        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: db
              .collection('branchCommissionSettings')
              .doc(branchId)
              .snapshots(),
          builder: (context, cs) {
            final setting = cs.data?.data() ?? {};
            final start = flashWeekStart(), end = flashWeekEnd();
            final delivered = os.data!.docs.where((o) {
              final d = o.data();
              final dt = flashDeliveredDate(d);
              return flashDelivered(d) &&
                  dt != null &&
                  !dt.isBefore(start) &&
                  dt.isBefore(end);
            }).toList();
            final sales = delivered.fold<double>(
              0,
              (v, o) => v + flashOrderSales(o.data()),
            );
            final rate = flashMoney(setting['commissionPercent']);
            double incentive = 0;
            final targets = setting['weeklyTargets'];
            if (targets is List)
              for (final raw in targets) {
                if (raw is Map && sales >= flashMoney(raw['salesAmount']))
                  incentive = incentive > flashMoney(raw['incentiveAmount'])
                      ? incentive
                      : flashMoney(raw['incentiveAmount']);
              }
            final commission = sales * rate / 100;
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'Weekly Earnings & Payout',
                  style: TextStyle(fontSize: 23, fontWeight: FontWeight.w900),
                ),
                Text(
                  'Branch: $currentAdminBranchName • Week ${flashWeekKey(start)}',
                  style: const TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        _payoutRow('Delivered orders', '${delivered.length}'),
                        _payoutRow(
                          'Eligible delivered sales',
                          '₹${sales.toStringAsFixed(2)}',
                        ),
                        _payoutRow(
                          'Commission rate',
                          '${rate.toStringAsFixed(2)}%',
                        ),
                        _payoutRow(
                          'Admin commission',
                          '₹${commission.toStringAsFixed(2)}',
                        ),
                        _payoutRow(
                          'Sales target incentive',
                          '₹${incentive.toStringAsFixed(2)}',
                        ),
                        const Divider(),
                        _payoutRow(
                          'Current week earning',
                          '₹${(commission + incentive).toStringAsFixed(2)}',
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                const Text(
                  'Delivery Partner Weekly Payouts',
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
                ),
                ..._partnerWeeklyCards(
                  context,
                  db,
                  os.data!.docs,
                  branchId,
                  start,
                  end,
                ),
                const SizedBox(height: 18),
                const Text(
                  'Payout History',
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
                ),
                StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: db
                      .collection('weeklyPayouts')
                      .where('recipientType', isEqualTo: 'admin')
                      .where('branchId', isEqualTo: branchId)
                      .snapshots(),
                  builder: (context, ps) {
                    if (ps.hasError)
                      return Text('History load error: ${ps.error}');
                    if (!ps.hasData) return const LinearProgressIndicator();
                    final list = [...ps.data!.docs]
                      ..sort(
                        (a, b) =>
                            (flashDate(b.data()['weekStart']) ?? DateTime(1970))
                                .compareTo(
                                  flashDate(a.data()['weekStart']) ??
                                      DateTime(1970),
                                ),
                      );
                    if (list.isEmpty)
                      return const Padding(
                        padding: EdgeInsets.all(12),
                        child: Text('अभी payout history उपलब्ध नहीं है.'),
                      );
                    return Column(
                      children: list.map((doc) {
                        final d = doc.data();
                        return Card(
                          child: ListTile(
                            title: Text('Week ${d['weekKey'] ?? ''}'),
                            subtitle: Text(
                              'Sales ₹${flashMoney(d['deliveredSales']).toStringAsFixed(2)} • Commission ₹${flashMoney(d['commissionAmount']).toStringAsFixed(2)} • Incentive ₹${flashMoney(d['incentiveAmount']).toStringAsFixed(2)}',
                            ),
                            trailing: Text(
                              (d['status'] ?? 'Pending').toString(),
                              style: TextStyle(
                                color: (d['status'] == 'Paid')
                                    ? Colors.green
                                    : orange,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    );
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }

  List<Widget> _partnerWeeklyCards(
    BuildContext context,
    FirebaseFirestore db,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> orders,
    String branchId,
    DateTime start,
    DateTime end,
  ) {
    final grouped = <String, Map<String, dynamic>>{};
    for (final doc in orders) {
      final d = doc.data();
      if (!flashDelivered(d)) continue;
      final partner = (d['deliveryPartnerId'] ?? '').toString().trim();
      final dt = flashDeliveredDate(d);
      if (partner.isEmpty ||
          dt == null ||
          dt.isBefore(start) ||
          !dt.isBefore(end))
        continue;
      final row = grouped.putIfAbsent(
        partner,
        () => {
          'uid': partner,
          'name':
              (d['deliveryPartnerName'] ??
                      d['partnerName'] ??
                      'Delivery Partner')
                  .toString(),
          'amount': 0.0,
          'count': 0,
        },
      );
      row['amount'] = (row['amount'] as double) + flashDeliveryEarning(d);
      row['count'] = (row['count'] as int) + 1;
    }
    if (grouped.isEmpty)
      return [
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text('इस सप्ताह कोई delivered partner order नहीं है.'),
        ),
      ];
    return grouped.values.map((row) {
      final uid = row['uid'] as String;
      return Card(
        child: ListTile(
          leading: const CircleAvatar(child: Icon(Icons.delivery_dining)),
          title: Text(
            row['name'].toString(),
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          subtitle: Text(
            '${row['count']} delivered orders • ₹${(row['amount'] as double).toStringAsFixed(2)} • ${flashWeekKey(start)}\nPayment केवल Founder & CEO App से होगा.',
          ),
          isThreeLine: true,
          trailing: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: db
                .collection('weeklyPayouts')
                .where('recipientUid', isEqualTo: uid)
                .snapshots(),
            builder: (context, snap) {
              final rows = (snap.data?.docs ?? [])
                  .where(
                    (x) =>
                        (x.data()['branchId'] ?? '').toString() == branchId &&
                        (x.data()['weekKey'] ?? '').toString() ==
                            flashWeekKey(start),
                  )
                  .toList();
              final paid = rows.any(
                (x) =>
                    (x.data()['status'] ?? '').toString().toLowerCase() ==
                    'paid',
              );
              return Chip(
                label: Text(paid ? 'Paid by CEO' : 'CEO payment pending'),
                backgroundColor: paid
                    ? const Color(0xFFE8F7ED)
                    : const Color(0xFFFFF0E9),
              );
            },
          ),
        ),
      );
    }).toList();
  }
}

Widget _payoutRow(String label, String value) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 5),
  child: Row(
    children: [
      Expanded(child: Text(label)),
      Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
    ],
  ),
);

// ============================================================
// ADMIN PROFILE — BRANCH-SCOPED
// ============================================================
class AdminProfilePage extends StatefulWidget {
  const AdminProfilePage({super.key});
  @override
  State<AdminProfilePage> createState() => _AdminProfilePageState();
}

class _AdminProfilePageState extends State<AdminProfilePage> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  bool _loaded = false, _saving = false;
  String _photoUrl = '';
  final _picker = ImagePicker();
  String get _uid => FirebaseAuth.instance.currentUser!.uid;

  Future<void> _load(Map<String, dynamic> d) async {
    if (_loaded) return;
    _loaded = true;
    _name.text = (d['name'] ?? d['fullName'] ?? d['adminName'] ?? '')
        .toString();
    _phone.text = (d['phone'] ?? d['mobile'] ?? d['mobileNumber'] ?? '')
        .toString();
    _email.text = (d['email'] ?? FirebaseAuth.instance.currentUser?.email ?? '')
        .toString();
    _photoUrl = (d['photoUrl'] ?? '').toString();
  }

  Future<void> _photo() async {
    final x = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 80,
      maxWidth: 1200,
    );
    if (x == null) return;
    setState(() => _saving = true);
    try {
      final ref = FirebaseStorage.instance.ref(
        'adminProfilePhotos/$_uid/${DateTime.now().millisecondsSinceEpoch}_${x.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}',
      );
      await ref.putData(
        await x.readAsBytes(),
        SettableMetadata(contentType: x.mimeType ?? 'image/jpeg'),
      );
      _photoUrl = await ref.getDownloadURL();
      await FirebaseFirestore.instance.collection('admins').doc(_uid).set({
        'photoUrl': _photoUrl,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      if (mounted) setState(() {});
    } catch (e) {
      _msg('Photo upload failed: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      _msg('नाम भरें');
      return;
    }
    setState(() => _saving = true);
    try {
      final update = {
        'uid': _uid,
        'name': _name.text.trim(),
        'fullName': _name.text.trim(),
        'phone': _phone.text.trim(),
        'mobile': _phone.text.trim(),
        'email': _email.text.trim(),
        'photoUrl': _photoUrl,
        'branchId': currentAdminBranchId,
        'branchName': currentAdminBranchName,
        'updatedAt': FieldValue.serverTimestamp(),
      };
      final db = FirebaseFirestore.instance;
      await db
          .collection('admins')
          .doc(_uid)
          .set(update, SetOptions(merge: true));
      await db
          .collection('managers')
          .doc(_uid)
          .set(update, SetOptions(merge: true));
      _msg('Profile save हो गई।');
    } catch (e) {
      _msg('Profile save नहीं हुई: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _msg(String s) {
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const Center(child: Text('Please login again.'));
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('admins')
          .doc(uid)
          .snapshots(),
      builder: (context, snap) {
        final d = snap.data?.data() ?? {};
        if (!_loaded && d.isNotEmpty)
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              _load(d);
              setState(() {});
            }
          });
        return Container(
          color: const Color(0xFFF6F7FB),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [orange, Color(0xFFFF9F43)],
                  ),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 32,
                      backgroundColor: Colors.white,
                      backgroundImage: _photoUrl.isEmpty
                          ? null
                          : NetworkImage(_photoUrl),
                      child: _photoUrl.isEmpty
                          ? const Icon(Icons.person, size: 36, color: orange)
                          : null,
                    ),
                    const SizedBox(width: 14),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'My Profile',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          Text(
                            'Manager / Branch Admin details',
                            style: TextStyle(color: Colors.white70),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: _saving ? null : _photo,
                      icon: const Icon(Icons.add_a_photo, color: Colors.white),
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
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    children: [
                      TextFormField(
                        controller: _name,
                        decoration: inputDecoration(
                          'Full name',
                          Icons.person_outline,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _phone,
                        keyboardType: TextInputType.phone,
                        decoration: inputDecoration(
                          'Mobile number',
                          Icons.phone_outlined,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        decoration: inputDecoration(
                          'Email',
                          Icons.email_outlined,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF0E9),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Text(
                          'Assigned Branch: ${currentAdminBranchName.isEmpty ? currentAdminBranchId : currentAdminBranchName}',
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                      const SizedBox(height: 18),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _saving ? null : _save,
                          icon: const Icon(Icons.save_rounded),
                          label: Text(_saving ? 'Saving…' : 'Save Profile'),
                          style: FilledButton.styleFrom(
                            backgroundColor: orange,
                            padding: const EdgeInsets.all(15),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ============================================================
// ADMIN — BRANCH PARTNER PAYOUTS (CEO APPROVAL REQUIRED)
// ============================================================
class AdminPartnerPayoutPage extends StatelessWidget {
  const AdminPartnerPayoutPage({super.key});

  @override
  Widget build(BuildContext context) {
    final branchId = currentAdminBranchId;
    final db = FirebaseFirestore.instance;
    if (branchId.isEmpty)
      return const Center(child: Text('Branch assign नहीं है।'));
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: db
          .collection('deliveryPartners')
          .where('branchId', isEqualTo: branchId)
          .snapshots(),
      builder: (context, ps) {
        if (ps.hasError)
          return Center(child: Text('Partners load error: ${ps.error}'));
        if (!ps.hasData)
          return const Center(child: CircularProgressIndicator());
        final partners = ps.data!.docs;
        return ListView(
          padding: const EdgeInsets.all(14),
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [orange, Color(0xFFFF9F43)],
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Branch Partner Payout Status',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Text(
                    'Bank verification और सभी payments केवल Founder & CEO करेंगे। यह स्क्रीन केवल status/history दिखाती है।',
                    style: TextStyle(color: Colors.white),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (partners.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Text('इस branch में partner profiles नहीं मिले।'),
              ),
            ...partners.map((doc) {
              final d = doc.data();
              final bank = Map<String, dynamic>.from(
                d['payoutBank'] is Map ? d['payoutBank'] : {},
              );
              final verified =
                  bank['verificationStatus'] == 'Verified' &&
                  bank['verified'] == true;
              final name = (d['name'] ?? d['fullName'] ?? 'Delivery Partner')
                  .toString();
              final account = (bank['accountNumber'] ?? '').toString();
              final masked = account.isEmpty
                  ? 'Not provided'
                  : '•••• ${account.length > 4 ? account.substring(account.length - 4) : account}';
              return Card(
                elevation: 0,
                margin: const EdgeInsets.only(bottom: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              name,
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                          Chip(
                            label: Text(
                              verified ? 'CEO VERIFIED' : 'PENDING CEO',
                            ),
                            backgroundColor: verified
                                ? const Color(0xFFE8F7ED)
                                : const Color(0xFFFFF0E9),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Bank: ${bank['bankName'] ?? '—'} • Account: $masked',
                      ),
                      Text(
                        'IFSC: ${bank['ifsc'] ?? '—'} • UPI: ${bank['upiId'] ?? '—'}',
                      ),
                      const SizedBox(height: 8),
                      StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                        stream: db
                            .collection('weeklyPayouts')
                            .where('recipientUid', isEqualTo: doc.id)
                            .snapshots(),
                        builder: (context, h) {
                          if (h.hasError)
                            return Text(
                              'Payout history load error: ${h.error}',
                            );
                          final rows =
                              (h.data?.docs ?? [])
                                  .where(
                                    (x) =>
                                        (x.data()['branchId'] ?? '')
                                            .toString() ==
                                        branchId,
                                  )
                                  .toList()
                                ..sort(
                                  (a, b) =>
                                      ((b.data()['updatedAt'] as Timestamp?)
                                                  ?.millisecondsSinceEpoch ??
                                              0)
                                          .compareTo(
                                            (a.data()['updatedAt']
                                                        as Timestamp?)
                                                    ?.millisecondsSinceEpoch ??
                                                0,
                                          ),
                                );
                          if (rows.isEmpty)
                            return const Text(
                              'अभी payout history उपलब्ध नहीं है।',
                            );
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: rows.take(5).map((x) {
                              final p = x.data();
                              return ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(
                                  (p['status'] == 'Paid')
                                      ? Icons.check_circle
                                      : Icons.pending_actions,
                                  color: (p['status'] == 'Paid')
                                      ? green
                                      : orange,
                                ),
                                title: Text(
                                  '₹${adminMoney(p['paidAmount'] ?? p['amount']).toStringAsFixed(2)} • ${p['status'] ?? 'Pending'}',
                                ),
                                subtitle: Text(
                                  'Week: ${p['weekKey'] ?? '—'} • UTR: ${p['paymentReference'] ?? '—'}',
                                ),
                              );
                            }).toList(),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              );
            }),
          ],
        );
      },
    );
  }
}

// ============================================================
// ADMIN BANK DETAILS (embedded so main.dart works as a direct replacement)
// ============================================================

/// Admin's own payout bank profile. Documents are uploaded through the
/// authenticated Supabase Edge Function; service-role secrets never belong here.
class AdminBankDetailsPage extends StatefulWidget {
  const AdminBankDetailsPage({
    super.key,
    required this.branchId,
    this.branchName = '',
  });

  final String branchId;
  final String branchName;

  @override
  State<AdminBankDetailsPage> createState() => _AdminBankDetailsPageState();
}

class _AdminBankDetailsPageState extends State<AdminBankDetailsPage> {
  final _formKey = GlobalKey<FormState>();
  final _holder = TextEditingController();
  final _bank = TextEditingController();
  final _account = TextEditingController();
  final _confirm = TextEditingController();
  final _ifsc = TextEditingController();
  final _upi = TextEditingController();
  final _picker = ImagePicker();
  String _documentPath = '';
  String _documentName = '';
  String _status = 'Not submitted';
  bool _loading = true, _uploading = false, _saving = false;

  DocumentReference<Map<String, dynamic>> get _adminRef {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    return FirebaseFirestore.instance.collection('admins').doc(uid);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) throw Exception('Admin login नहीं है।');
      final db = FirebaseFirestore.instance;
      final a = await db.collection('admins').doc(uid).get();
      final m = await db.collection('managers').doc(uid).get();
      final d = a.data() ?? m.data() ?? <String, dynamic>{};
      final b = Map<String, dynamic>.from(
        d['payoutBank'] is Map ? d['payoutBank'] : {},
      );
      _holder.text = '${b['accountHolderName'] ?? ''}';
      _bank.text = '${b['bankName'] ?? ''}';
      _account.text = '${b['accountNumber'] ?? ''}';
      _confirm.text = _account.text;
      _ifsc.text = '${b['ifsc'] ?? ''}';
      _upi.text = '${b['upiId'] ?? ''}';
      _documentPath = '${b['documentPath'] ?? ''}';
      _documentName = '${b['documentName'] ?? ''}';
      _status = '${b['verificationStatus'] ?? 'Not submitted'}';
    } catch (e) {
      _message('Bank details load नहीं हुए: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _upload() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _message('पहले Admin login करें।');
      return;
    }
    final file = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 82,
      maxWidth: 1800,
    );
    if (file == null) return;
    setState(() => _uploading = true);
    try {
      const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
      const publishableKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
      if (supabaseUrl.isEmpty || publishableKey.isEmpty) {
        throw Exception(
          'Build में SUPABASE_URL और SUPABASE_PUBLISHABLE_KEY सेट नहीं हैं।',
        );
      }
      final token = await user.getIdToken(true);
      if (token == null) throw Exception('Firebase token नहीं मिला।');
      final bytes = await file.readAsBytes();
      final n = file.name.toLowerCase();
      final contentType = n.endsWith('.png')
          ? 'image/png'
          : n.endsWith('.webp')
          ? 'image/webp'
          : 'image/jpeg';
      final response = await http.post(
        Uri.parse('$supabaseUrl/functions/v1/partner-bank-upload'),
        headers: {
          'apikey': publishableKey,
          'Authorization': 'Bearer $token',
          'Content-Type': contentType,
        },
        body: bytes,
      );
      final decoded = jsonDecode(response.body);
      if (response.statusCode != 200 ||
          decoded is! Map ||
          decoded['path'] == null) {
        throw Exception(
          decoded is Map
              ? (decoded['error'] ?? 'Upload failed')
              : 'Upload failed',
        );
      }
      if (!mounted) return;
      setState(() {
        _documentPath = decoded['path'].toString();
        _documentName = file.name;
      });
      _message('Document upload हो गया। अब Save Bank Details दबाएँ।');
    } catch (e) {
      _message('Upload नहीं हुआ: $e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_account.text.trim() != _confirm.text.trim()) {
      _message('दोनों Account Number एक जैसे होने चाहिए।');
      return;
    }
    if (_documentPath.isEmpty) {
      _message('Cancelled Cheque या Passbook upload करें।');
      return;
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _message('Admin login नहीं है।');
      return;
    }
    setState(() => _saving = true);
    try {
      final bank = <String, dynamic>{
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
      };
      final payload = <String, dynamic>{
        'uid': user.uid,
        'branchId': widget.branchId,
        'branchName': widget.branchName,
        'payoutBank': bank,
        'updatedAt': FieldValue.serverTimestamp(),
      };
      final db = FirebaseFirestore.instance;
      final batch = db.batch();
      batch.set(
        db.collection('admins').doc(user.uid),
        payload,
        SetOptions(merge: true),
      );
      // Keep manager profile in sync where the existing login flow stores it.
      batch.set(
        db.collection('managers').doc(user.uid),
        payload,
        SetOptions(merge: true),
      );
      await batch.commit();
      if (mounted) {
        setState(() => _status = 'Pending');
        _message('Bank details CEO verification के लिए भेज दी गई हैं।');
      }
    } catch (e) {
      _message('Save नहीं हुआ: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _message(String text) {
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

  InputDecoration _dec(String label, IconData icon) => InputDecoration(
    labelText: label,
    prefixIcon: Icon(icon),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
  );
  String? _required(String? v) =>
      (v == null || v.trim().isEmpty) ? 'यह जानकारी भरें' : null;

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return Scaffold(
      appBar: AppBar(title: const Text('My Bank Details')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFFFF6B35), Color(0xFFFF9F43)],
              ),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Admin Bank Account',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                SizedBox(height: 5),
                Text(
                  'Account details और cancelled cheque/passbook CEO verification के लिए भेजें।',
                  style: TextStyle(color: Colors.white),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.verified_user_outlined),
              title: const Text('Verification Status'),
              trailing: Text(
                _status,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: _status.toLowerCase() == 'verified'
                      ? Colors.green
                      : Colors.orange,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Form(
            key: _formKey,
            child: Column(
              children: [
                TextFormField(
                  controller: _holder,
                  decoration: _dec('Account Holder Name', Icons.person_outline),
                  validator: _required,
                  textCapitalization: TextCapitalization.words,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _bank,
                  decoration: _dec('Bank Name', Icons.account_balance),
                  validator: _required,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _account,
                  decoration: _dec('Account Number', Icons.credit_card),
                  keyboardType: TextInputType.number,
                  validator: _required,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _confirm,
                  decoration: _dec(
                    'Confirm Account Number',
                    Icons.check_circle_outline,
                  ),
                  keyboardType: TextInputType.number,
                  validator: _required,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _ifsc,
                  decoration: _dec('IFSC Code', Icons.tag),
                  validator: (v) {
                    if (v == null ||
                        !RegExp(r'^[A-Za-z]{4}0[A-Za-z0-9]{6}$')
                            .hasMatch(v.trim()))
                      return 'Valid IFSC भरें';
                    return null;
                  },
                  textCapitalization: TextCapitalization.characters,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _upi,
                  decoration: _dec('UPI ID (Optional)', Icons.qr_code_2),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: _uploading ? null : _upload,
            icon: _uploading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.upload_file),
            label: Text(
              _uploading
                  ? 'Uploading...'
                  : (_documentPath.isEmpty
                        ? 'Upload Cancelled Cheque / Passbook'
                        : 'Document Uploaded: $_documentName'),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 52,
            child: FilledButton.icon(
              onPressed: _saving || _uploading ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.save),
              label: Text(_saving ? 'Saving...' : 'Save Bank Details'),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'नोट: Save करने के बाद CEO App में Verification Status Pending दिखना चाहिए। Private Supabase bucket और Edge Function permissions सही configured होने चाहिए.',
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
