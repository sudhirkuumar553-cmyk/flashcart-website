import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:image_picker/image_picker.dart';
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
];

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  runApp(const FlashCartCeoApp());
}

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

class FlashCartCeoApp extends StatelessWidget {
  const FlashCartCeoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'FlashCart Founder & CEO',
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
      final accessDoc = await FirebaseFirestore.instance
          .collection('ceoAccess')
          .doc(uid)
          .get(const GetOptions(source: Source.server));
      final access = accessDoc.data() ?? <String, dynamic>{};
      final allowed =
          accessDoc.exists &&
          access['active'] == true &&
          (access['role'] == 'ceo' || access['role'] == 'founder');
      if (!allowed) {
        await FirebaseAuth.instance.signOut();
        message(
          'CEO permission नहीं मिली। ceoAccess/$uid में active=true और role=ceo/founder जाँचें।',
        );
        return;
      }

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
                      'FOUNDER & CEO CONTROL',
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
                        'CEO Email',
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
                                'LOGIN TO FOUNDER & CEO',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
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

// ============================================================
// DASHBOARD
// ============================================================

class AdminDashboardPage extends StatefulWidget {
  const AdminDashboardPage({super.key});

  @override
  State<AdminDashboardPage> createState() => _AdminDashboardPageState();
}

class _AdminDashboardPageState extends State<AdminDashboardPage> {
  int selectedIndex = 0;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  // Primary sections stay in the bottom bar; all other CEO modules remain
  // available through the More drawer.
  int get _bottomNavIndex {
    switch (selectedIndex) {
      case 0:
        return 0; // Home / Dashboard
      case 2:
        return 1; // Orders
      case 1:
        return 2; // Products
      case 11:
        return 3; // Reports & Analytics
      default:
        return 4; // More
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

  final pages = const [
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
    CeoOrderControlPage(),
    CeoServiceAreaPage(),
    BranchSalesAnalyticsPage(),
    ManagerRegistrationPage(),
    OrderArchivePage(),
    CeoWeeklyPayoutCommissionPage(),
    DeliveryPartnerEarningsPage(),
    CeoPartnerBankVerificationPage(),
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
    'Customer Order Control',
    'Customer Location & Radius',
    'Branch Sales & Performance',
    'Admin / Store Registration',
    'Orders Archive & Delete',
    'Weekly Payout & Admin Incentives',
    'Delivery Partner Earnings & Payments',
    'Bank Details & Verification',
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
        toolbarHeight: 76,
        titleSpacing: 4,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'Hi, Founder 👋',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.w900,
                color: Color(0xFF171717),
              ),
            ),
            SizedBox(height: 2),
            Text(
              'FlashCart Founder & CEO',
              style: TextStyle(
                fontSize: 14,
                color: Color(0xFF858585),
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
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
      bottomNavigationBar: NavigationBar(
        selectedIndex: _bottomNavIndex,
        height: 76,
        backgroundColor: Colors.white,
        indicatorColor: lightOrange,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        onDestinationSelected: _onBottomNavTap,
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
            icon: Icon(Icons.inventory_2_outlined),
            selectedIcon: Icon(Icons.inventory_2_rounded, color: orange),
            label: 'Products',
          ),
          NavigationDestination(
            icon: Icon(Icons.analytics_outlined),
            selectedIcon: Icon(Icons.analytics_rounded, color: orange),
            label: 'Reports',
          ),
          NavigationDestination(
            icon: Icon(Icons.menu_rounded),
            selectedIcon: Icon(Icons.menu_open_rounded, color: orange),
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
                  drawerItem(14, Icons.settings_rounded, 'App Settings'),
                  _drawerSection('CEO CONTROL'),
                  drawerItem(
                    16,
                    Icons.schedule_rounded,
                    'Customer Order Control',
                  ),
                  drawerItem(
                    17,
                    Icons.location_on_rounded,
                    'Customer Location & Radius',
                  ),
                  drawerItem(
                    18,
                    Icons.leaderboard_rounded,
                    'Branch Sales & Performance',
                  ),
                  drawerItem(
                    19,
                    Icons.store_mall_directory_rounded,
                    'Admin / Store Registration',
                  ),
                  drawerItem(
                    20,
                    Icons.archive_rounded,
                    'Orders Archive & Delete',
                  ),
                  drawerItem(
                    21,
                    Icons.account_balance_wallet_rounded,
                    'Weekly Payout & Admin Incentives',
                  ),
                  drawerItem(
                    22,
                    Icons.payments_rounded,
                    'Delivery Partner Earnings & Payments',
                  ),
                  drawerItem(
                    23,
                    Icons.account_balance_rounded,
                    'Bank Details & Verification',
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
    return FirebaseFirestore.instance
        .collection(collection)
        .snapshots()
        .map((snapshot) => snapshot.docs.length);
  }

  // Total sales from all orders. Supports the common total field names so
  // the dashboard keeps working with existing order documents.
  Stream<double> totalSales() {
    return FirebaseFirestore.instance.collection('orders').snapshots().map((
      snapshot,
    ) {
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

  // Branch-wise delivered sales for the dashboard.
  Stream<List<Map<String, dynamic>>> branchSales() {
    return FirebaseFirestore.instance.collection('orders').snapshots().map((
      snapshot,
    ) {
      final totals = <String, Map<String, dynamic>>{};
      for (final doc in snapshot.docs) {
        final data = doc.data();
        if ((data['status'] ?? '').toString().toLowerCase() != 'delivered')
          continue;
        final branchId = (data['branchId'] ?? data['storeId'] ?? '')
            .toString()
            .trim();
        final branchName =
            (data['branchName'] ?? data['storeName'] ?? data['store'] ?? '')
                .toString()
                .trim();
        final key = branchId.isNotEmpty
            ? branchId
            : (branchName.isNotEmpty ? branchName : 'unknown');
        final row = totals.putIfAbsent(
          key,
          () => {
            'branchId': branchId,
            'branchName': branchName.isNotEmpty
                ? branchName
                : (branchId.isNotEmpty
                      ? 'Branch ${branchId.substring(0, branchId.length > 8 ? 8 : branchId.length)}'
                      : 'Branch not recorded'),
            'sales': 0.0,
            'orders': 0,
          },
        );
        row['sales'] = (row['sales'] as double) + _extractOrderTotal(data);
        row['orders'] = (row['orders'] as int) + 1;
      }
      final rows = totals.values.toList();
      rows.sort(
        (a, b) => (b['sales'] as double).compareTo(a['sales'] as double),
      );
      return rows;
    });
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
              'Good day, Founder 👋',
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
            const SizedBox(height: 18),
            const Text(
              'Branch / Store Wise Sales',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 6),
            const Text(
              'हर branch/store की delivered orders से हुई बिक्री',
              style: TextStyle(color: grey),
            ),
            const SizedBox(height: 10),
            StreamBuilder<List<Map<String, dynamic>>>(
              stream: branchSales(),
              builder: (context, snapshot) {
                if (snapshot.hasError)
                  return const Card(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'Branch sales लोड नहीं हो सकी। Firestore rules जाँचें।',
                      ),
                    ),
                  );
                if (!snapshot.hasData)
                  return const Card(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  );
                final rows = snapshot.data!;
                if (rows.isEmpty)
                  return const Card(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'अभी कोई Delivered order नहीं है। Orders में branchName/storeName और branchId/storeId सेव होने पर बिक्री यहाँ दिखेगी।',
                      ),
                    ),
                  );
                return Column(
                  children: rows
                      .map(
                        (row) => Card(
                          margin: const EdgeInsets.only(bottom: 10),
                          child: ListTile(
                            leading: const CircleAvatar(
                              backgroundColor: Color(0xFFFFEFE8),
                              child: Icon(
                                Icons.storefront_rounded,
                                color: orange,
                              ),
                            ),
                            title: Text(
                              row['branchName'].toString(),
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            subtitle: Text('${row['orders']} delivered orders'),
                            trailing: Text(
                              formatSales(row['sales'] as double),
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        ),
                      )
                      .toList(),
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
      await FirebaseFirestore.instance.collection('products').doc(id).delete();

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
                  .orderBy('createdAt', descending: true)
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
                  '$unit • Stock: $stock',
                  style: const TextStyle(color: grey, fontSize: 12),
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

    setState(() => saving = true);

    try {
      final imageUrl = await uploadImage();

      final data = <String, dynamic>{
        'name': name,
        'originalPrice': original,
        'discount': discount,
        'sellingPrice': sellingPrice,
        'unit': unit,
        'category': selectedCategory,
        'stock': stock,
        'available': available,
        'imageUrl': imageUrl,
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (widget.editing) {
        await FirebaseFirestore.instance
            .collection('products')
            .doc(widget.productId)
            .update(data);
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
          .orderBy('name')
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
    await FirebaseFirestore.instance.collection('categories').doc(id).delete();
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
            .orderBy('name')
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
// CEO ORDER ARCHIVE & PERMANENT DELETE
// This page only manages terminal orders. Active/in-progress orders
// are intentionally protected from archiving.
// ============================================================

class OrderArchivePage extends StatefulWidget {
  const OrderArchivePage({super.key});

  @override
  State<OrderArchivePage> createState() => _OrderArchivePageState();
}

class _OrderArchivePageState extends State<OrderArchivePage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  bool _isTerminal(String status) {
    final s = status.trim().toLowerCase();
    return s == 'delivered' || s == 'cancelled' || s == 'cancelled by customer';
  }

  Future<void> _archiveOrder(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) async {
    if (_busy) return;
    final data = doc.data();
    final status = (data['status'] ?? '').toString();
    if (!_isTerminal(status)) {
      _message('सिर्फ Delivered या Cancelled order archive किया जा सकता है।');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Archive Order?'),
        content: Text(
          'Order ID: ${doc.id}\n\nयह order active Orders से हटकर Archived Orders में सुरक्षित होगा।',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.archive_outlined),
            label: const Text('Archive'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    try {
      final db = FirebaseFirestore.instance;
      final orderRef = db.collection('orders').doc(doc.id);
      final archiveRef = db.collection('archivedOrders').doc(doc.id);
      await db.runTransaction((tx) async {
        final freshOrder = await tx.get(orderRef);
        final freshArchive = await tx.get(archiveRef);
        if (!freshOrder.exists)
          throw Exception('Order अब active सूची में नहीं है।');
        if (freshArchive.exists)
          throw Exception('यह order पहले से archived है।');

        final freshData = freshOrder.data() ?? <String, dynamic>{};
        final freshStatus = (freshData['status'] ?? '').toString();
        if (!_isTerminal(freshStatus)) {
          throw Exception('Order का status बदल गया है; archive नहीं किया गया।');
        }

        tx.set(archiveRef, {
          ...freshData,
          'originalOrderId': doc.id,
          'archivedAt': FieldValue.serverTimestamp(),
          'archivedBy': FirebaseAuth.instance.currentUser?.uid ?? '',
          'archiveVersion': 1,
        });
        tx.delete(orderRef);
      });
      _message('Order सफलतापूर्वक archive हो गया।');
    } catch (e) {
      _message('Archive नहीं हुआ: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _permanentlyDelete(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(
          Icons.warning_amber_rounded,
          color: Colors.red,
          size: 36,
        ),
        title: const Text('Permanent Delete?'),
        content: Text(
          'Order ID: ${doc.id}\n\nयह archived order हमेशा के लिए delete होगा। यह कार्रवाई वापस नहीं की जा सकती।',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep Order'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Permanently Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    try {
      final db = FirebaseFirestore.instance;
      final ref = db.collection('archivedOrders').doc(doc.id);
      await db.runTransaction((tx) async {
        final snap = await tx.get(ref);
        if (!snap.exists) throw Exception('Archived order नहीं मिला।');
        tx.delete(ref);
      });
      _message('Archived order permanently delete हो गया।');
    } catch (e) {
      _message('Permanent delete नहीं हुआ: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
    );
  }

  String _orderTitle(Map<String, dynamic> d) {
    final value = d['orderNumber'] ?? d['orderId'] ?? d['id'];
    return value == null || value.toString().trim().isEmpty
        ? 'Order'
        : 'Order ${value.toString()}';
  }

  String _customerName(Map<String, dynamic> d) {
    return (d['customerName'] ?? d['name'] ?? d['userName'] ?? 'Customer')
        .toString();
  }

  String _amount(Map<String, dynamic> d) {
    final value =
        d['total'] ??
        d['totalAmount'] ??
        d['grandTotal'] ??
        d['finalTotal'] ??
        d['amount'] ??
        0;
    return '₹${value.toString()}';
  }

  Widget _orderList({required bool archived}) {
    final collection = archived ? 'archivedOrders' : 'orders';
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection(collection).snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Orders लोड नहीं हुए। Firestore rules में CEO access जाँचें।\n${snapshot.error}',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(color: orange));
        }
        final docs = snapshot.data?.docs ?? [];
        docs.sort((a, b) {
          final av = a.data()[archived ? 'archivedAt' : 'createdAt'];
          final bv = b.data()[archived ? 'archivedAt' : 'createdAt'];
          final ad = av is Timestamp
              ? av.toDate()
              : DateTime.fromMillisecondsSinceEpoch(0);
          final bd = bv is Timestamp
              ? bv.toDate()
              : DateTime.fromMillisecondsSinceEpoch(0);
          return bd.compareTo(ad);
        });
        if (docs.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  archived
                      ? Icons.archive_outlined
                      : Icons.shopping_bag_outlined,
                  size: 54,
                  color: Colors.grey.shade400,
                ),
                const SizedBox(height: 10),
                Text(
                  archived
                      ? 'कोई Archived Order नहीं है'
                      : 'कोई Active Order नहीं है',
                ),
              ],
            ),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(14),
          itemCount: docs.length,
          itemBuilder: (context, index) {
            final doc = docs[index];
            final data = doc.data();
            final status = (data['status'] ?? 'Unknown').toString();
            final branch =
                (data['branchName'] ??
                        data['storeName'] ??
                        'Branch not recorded')
                    .toString();
            final canArchive = _isTerminal(status);
            return Card(
              margin: const EdgeInsets.only(bottom: 10),
              elevation: 0,
              color: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
                side: BorderSide(color: Colors.grey.shade200),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          backgroundColor: archived
                              ? Colors.orange.shade50
                              : lightOrange,
                          child: Icon(
                            archived
                                ? Icons.archive_rounded
                                : Icons.receipt_long_rounded,
                            color: orange,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _orderTitle(data),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              Text(
                                'ID: ${doc.id}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: grey,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          _amount(data),
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            color: orange,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text('Customer: ${_customerName(data)}'),
                    Text(
                      'Branch: $branch',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Chip(
                          label: Text(status),
                          visualDensity: VisualDensity.compact,
                          backgroundColor: _isTerminal(status)
                              ? Colors.green.shade50
                              : Colors.blue.shade50,
                        ),
                        if (!archived && !canArchive)
                          const Text(
                            'पहले order complete/cancel करें',
                            style: TextStyle(fontSize: 11, color: grey),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerRight,
                      child: archived
                          ? FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: Colors.red,
                              ),
                              onPressed: _busy
                                  ? null
                                  : () => _permanentlyDelete(doc),
                              icon: const Icon(Icons.delete_forever_rounded),
                              label: const Text('Permanent Delete'),
                            )
                          : OutlinedButton.icon(
                              onPressed: (_busy || !canArchive)
                                  ? null
                                  : () => _archiveOrder(doc),
                              icon: const Icon(Icons.archive_outlined),
                              label: const Text('Archive Order'),
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

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          color: Colors.white,
          child: TabBar(
            controller: _tabs,
            labelColor: orange,
            unselectedLabelColor: grey,
            indicatorColor: orange,
            tabs: const [
              Tab(
                icon: Icon(Icons.shopping_bag_outlined),
                text: 'Active Orders',
              ),
              Tab(icon: Icon(Icons.archive_outlined), text: 'Archived Orders'),
            ],
          ),
        ),
        if (_busy) const LinearProgressIndicator(color: orange, minHeight: 2),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: [_orderList(archived: false), _orderList(archived: true)],
          ),
        ),
      ],
    );
  }
}

Widget _ceoOrderItems(Map<String, dynamic> data) {
  final raw =
      data['items'] ??
      data['orderItems'] ??
      data['cartItems'] ??
      data['products'];
  if (raw is! List || raw.isEmpty) {
    return const Padding(
      padding: EdgeInsets.only(top: 8),
      child: Text(
        'Products: इस order में product details सेव नहीं हैं।',
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
      border: Border.all(color: Colors.grey.shade200),
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
      final currentStatus =
          orderData['status']?.toString().trim().toLowerCase() ?? '';
      if (currentStatus == 'delivered' ||
          currentStatus == 'cancelled' ||
          currentStatus == 'cancelled by customer') {
        throw Exception('यह order पहले ही complete/cancelled है।');
      }

      final partnerSnap = await db
          .collection('deliveryPartners')
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
      stream: FirebaseFirestore.instance.collection('orders').snapshots(),
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
            final status = data['status']?.toString() ?? 'Order Placed';
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

                  _ceoOrderItems(data),

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
                    onPressed: status.toLowerCase() == 'delivered'
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
    final snapshot = await _db.collection('orders').get();

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

      final partnersSnap = await _db.collection('deliveryPartners').get();

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
    final branchId = (data['branchId'] ?? data['storeId'] ?? '')
        .toString()
        .trim();
    final branchName = (data['branchName'] ?? data['storeName'] ?? '')
        .toString()
        .trim();
    if (branchId.isEmpty || branchName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'इस आवेदन में Store/Branch ID नहीं है। पहले सही Branch चुनकर आवेदन ठीक करें; बिना Branch के approve न करें।',
          ),
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
        // Keep the branch chosen during registration on the approved profile.
        'branchId': (data['branchId'] ?? data['storeId'] ?? '').toString(),
        'branchName': (data['branchName'] ?? data['storeName'] ?? '')
            .toString(),
        'storeId': (data['storeId'] ?? data['branchId'] ?? '').toString(),
        'storeName': (data['storeName'] ?? data['branchName'] ?? '').toString(),
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

  String _normalizedPhone(Map<String, dynamic> data) {
    var digits = (data['phone'] ?? data['mobile'] ?? data['mobileNumber'] ?? '')
        .toString()
        .replaceAll(RegExp(r'\D'), '');
    if (digits.startsWith('91') && digits.length == 12)
      digits = digits.substring(2);
    if (digits.length == 11 && digits.startsWith('0'))
      digits = digits.substring(1);
    return digits;
  }

  Future<void> transferPartner(
    BuildContext context,
    String partnerId,
    Map<String, dynamic> data,
  ) async {
    if (data['online'] == true ||
        (data['activeOrderId']?.toString().trim().isNotEmpty ?? false)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'पहले Partner को Offline करें और उसका active order पूरा होने दें।',
          ),
        ),
      );
      return;
    }
    try {
      final storeSnap = await FirebaseFirestore.instance
          .collection('publicStores')
          .where('active', isEqualTo: true)
          .get();
      final stores = storeSnap.docs.where((d) {
        final branch = (d.data()['branchId'] ?? d.id).toString();
        return branch.isNotEmpty &&
            branch != (data['branchId'] ?? '').toString();
      }).toList();
      if (stores.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('दूसरा Active Store उपलब्ध नहीं है।')),
          );
        }
        return;
      }
      String? selectedId = (stores.first.data()['branchId'] ?? stores.first.id)
          .toString();
      if (!context.mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) => AlertDialog(
            title: const Text('Store Transfer'),
            content: DropdownButtonFormField<String>(
              value: selectedId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'नया Store चुनें'),
              items: stores.map((d) {
                final m = d.data();
                final id = (m['branchId'] ?? d.id).toString();
                final name = (m['storeName'] ?? m['branchName'] ?? 'Store')
                    .toString();
                return DropdownMenuItem<String>(
                  value: id,
                  child: Text(name, overflow: TextOverflow.ellipsis),
                );
              }).toList(),
              onChanged: (v) => setDialogState(() => selectedId = v),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Transfer'),
              ),
            ],
          ),
        ),
      );
      if (confirmed != true || selectedId == null) return;
      final chosen = stores.firstWhere(
        (d) => (d.data()['branchId'] ?? d.id).toString() == selectedId,
      );
      final storeData = chosen.data();
      final branchName =
          (storeData['storeName'] ?? storeData['branchName'] ?? '').toString();
      await FirebaseFirestore.instance
          .collection('deliveryPartners')
          .doc(partnerId)
          .update({
            'branchId': selectedId,
            'branchName': branchName,
            'storeId': selectedId,
            'storeName': branchName,
            'online': false,
            'availableForOrder': false,
            'adminOnlineEnabled': false,
            'requiresAdminReactivation': true,
            'transferredAt': FieldValue.serverTimestamp(),
            'transferredBy': FirebaseAuth.instance.currentUser?.uid ?? '',
            'updatedAt': FieldValue.serverTimestamp(),
          });
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Store Transfer सफल। वही Partner ID रखी गई है; Admin को फिर से activate करना होगा।',
            ),
          ),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Store Transfer नहीं हो पाया। CEO access और Store Directory जाँचें।',
            ),
          ),
        );
      }
    }
  }

  Future<void> deleteUnusedPartner(
    BuildContext context,
    String partnerId,
    Map<String, dynamic> data,
  ) async {
    if (data['online'] == true ||
        (data['activeOrderId']?.toString().trim().isNotEmpty ?? false) ||
        data['availableForOrder'] == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'यह Partner active/available है। पहले deactivate करें और active order पूरा करें।',
          ),
        ),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Unused Partner हटाएँ?'),
        content: Text(
          'क्या ${data['name'] ?? data['fullName'] ?? 'इस Partner'} (${data['phone'] ?? data['mobile'] ?? 'मोबाइल उपलब्ध नहीं'}) की ID ${partnerId} स्थायी रूप से हटानी है? यह कदम वापस नहीं किया जा सकता। पहले सुनिश्चित करें कि यह duplicate/unused ID है और इसमें जरूरी payout/history नहीं है।',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete permanently'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final orderSnap = await FirebaseFirestore.instance
          .collection('orders')
          .where('deliveryPartnerId', isEqualTo: partnerId)
          .get();
      const completed = {
        'delivered',
        'cancelled',
        'canceled',
        'completed',
        'rejected',
      };
      final hasActiveOrder = orderSnap.docs.any((d) {
        final status = (d.data()['status'] ?? d.data()['orderStatus'] ?? '')
            .toString()
            .toLowerCase();
        return !completed.contains(status);
      });
      if (hasActiveOrder) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'इस Partner से जुड़ा active order मिला। Order पूरा/रद्द होने तक delete नहीं किया गया।',
              ),
            ),
          );
        }
        return;
      }
      await FirebaseFirestore.instance
          .collection('deliveryPartners')
          .doc(partnerId)
          .delete();
      final applicationId = data['applicationId']?.toString() ?? '';
      if (applicationId.isNotEmpty) {
        await FirebaseFirestore.instance
            .collection('deliveryPartnerApplications')
            .doc(applicationId)
            .set({
              'status': 'duplicate_deleted',
              'deletedPartnerId': partnerId,
              'reviewedAt': FieldValue.serverTimestamp(),
              'reviewedBy': FirebaseAuth.instance.currentUser?.uid ?? '',
            }, SetOptions(merge: true));
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unused Partner ID हटा दी गई।')),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Delete नहीं हो पाया। CEO Rules और active order स्थिति जाँचें।',
            ),
          ),
        );
      }
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
                            data['mobileNumber']?.toString() ??
                            '';
                        final normalizedPhone = _normalizedPhone(data);
                        final duplicateCount = docs.where((other) {
                          final otherData =
                              other.data() as Map<String, dynamic>;
                          return normalizedPhone.isNotEmpty &&
                              _normalizedPhone(otherData) == normalizedPhone;
                        }).length;

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
                              '${available ? 'AVAILABLE' : 'BUSY'}'
                              '${duplicateCount > 1 ? '\n⚠ Duplicate mobile: $duplicateCount profiles' : ''}',
                              style: TextStyle(
                                color: duplicateCount > 1
                                    ? Colors.red.shade700
                                    : null,
                              ),
                            ),
                            isThreeLine: true,
                            trailing: PopupMenuButton<String>(
                              tooltip: 'Partner actions',
                              onSelected: (action) {
                                if (action == 'active')
                                  setActive(context, doc.id, !active);
                                if (action == 'transfer')
                                  transferPartner(context, doc.id, data);
                                if (action == 'delete')
                                  deleteUnusedPartner(context, doc.id, data);
                              },
                              itemBuilder: (_) => [
                                PopupMenuItem(
                                  value: 'active',
                                  child: Text(
                                    active ? 'Deactivate' : 'Activate',
                                  ),
                                ),
                                const PopupMenuItem(
                                  value: 'transfer',
                                  child: Text('Transfer to another Store'),
                                ),
                                const PopupMenuItem(
                                  value: 'delete',
                                  child: Text('Delete unused Partner'),
                                ),
                              ],
                              icon: const Icon(Icons.more_vert),
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
      stream: FirebaseFirestore.instance.collection('orders').snapshots(),
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

// ============================================================
// CEO CUSTOMER ORDER SCHEDULE CONTROL
// Firestore: appConfig/businessAvailability
// ============================================================
class CeoOrderControlPage extends StatefulWidget {
  const CeoOrderControlPage({super.key});
  @override
  State<CeoOrderControlPage> createState() => _CeoOrderControlPageState();
}

class _CeoOrderControlPageState extends State<CeoOrderControlPage> {
  static const _days = <String>[
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  final _messageController = TextEditingController(
    text: 'अभी नए ऑर्डर बंद हैं। कृपया बाद में प्रयास करें।',
  );
  final Map<String, bool> _enabled = {for (final d in _days) d: true};
  final Map<String, TimeOfDay> _open = {
    for (final d in _days) d: const TimeOfDay(hour: 8, minute: 0),
  };
  final Map<String, TimeOfDay> _close = {
    for (final d in _days) d: const TimeOfDay(hour: 22, minute: 0),
  };
  bool _accepting = true,
      _scheduleEnabled = true,
      _loading = true,
      _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  TimeOfDay _parseTime(dynamic raw, TimeOfDay fallback) {
    if (raw is! String) return fallback;
    final parts = raw.split(':');
    if (parts.length != 2) return fallback;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59)
      return fallback;
    return TimeOfDay(hour: h, minute: m);
  }

  String _formatTime(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  Future<void> _load() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('appConfig')
          .doc('businessAvailability')
          .get();
      final d = snap.data() ?? <String, dynamic>{};
      _accepting = d['acceptingOrders'] != false;
      _scheduleEnabled = d['scheduleEnabled'] == true;
      _messageController.text =
          (d['customerMessage'] ??
                  'अभी नए ऑर्डर बंद हैं। कृपया बाद में प्रयास करें।')
              .toString();
      final schedule = d['weeklySchedule'];
      if (schedule is Map) {
        for (final day in _days) {
          final v = schedule[day];
          if (v is Map) {
            _enabled[day] = v['enabled'] != false;
            _open[day] = _parseTime(v['openTime'], _open[day]!);
            _close[day] = _parseTime(v['closeTime'], _close[day]!);
          }
        }
      } else {
        final open = _parseTime(
          d['openTime'],
          const TimeOfDay(hour: 8, minute: 0),
        );
        final close = _parseTime(
          d['closeTime'],
          const TimeOfDay(hour: 22, minute: 0),
        );
        for (final day in _days) {
          _open[day] = open;
          _close[day] = close;
        }
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Settings load नहीं हुईं: $e')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickTime(String day, bool opening) async {
    final value = await showTimePicker(
      context: context,
      initialTime: opening ? _open[day]! : _close[day]!,
    );
    if (value != null && mounted)
      setState(() {
        if (opening) {
          _open[day] = value;
        } else {
          _close[day] = value;
        }
      });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final weekly = <String, dynamic>{};
      for (final day in _days) {
        weekly[day] = {
          'enabled': _enabled[day],
          'openTime': _formatTime(_open[day]!),
          'closeTime': _formatTime(_close[day]!),
        };
      }
      await FirebaseFirestore.instance
          .collection('appConfig')
          .doc('businessAvailability')
          .set({
            'acceptingOrders': _accepting,
            'scheduleEnabled': _scheduleEnabled,
            'weeklySchedule': weekly,
            'customerMessage': _messageController.text.trim().isEmpty
                ? 'अभी नए ऑर्डर बंद हैं। कृपया बाद में प्रयास करें।'
                : _messageController.text.trim(),
            'timezone': 'Asia/Kolkata',
            'updatedAt': FieldValue.serverTimestamp(),
            'updatedBy': FirebaseAuth.instance.currentUser?.uid ?? '',
          }, SetOptions(merge: true));
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Customer order settings save हो गईं ✓'),
          ),
        );
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Save failed: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading)
      return const Center(child: CircularProgressIndicator(color: orange));
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Customer Order Control',
          style: TextStyle(fontSize: 25, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 6),
        const Text(
          'CEO यहाँ से नए ऑर्डर तुरंत रोक सकता है और हर दिन की opening/closing time अलग सेट कर सकता है। समय IST (India) के अनुसार रखें।',
          style: TextStyle(color: grey),
        ),
        const SizedBox(height: 14),
        Card(
          child: SwitchListTile(
            title: const Text(
              'Accepting New Orders',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text(
              _accepting
                  ? 'नए ऑर्डर स्वीकार होंगे (schedule के नियम भी लागू होंगे)'
                  : 'सभी नए ऑर्डर तुरंत बंद',
            ),
            value: _accepting,
            onChanged: (v) => setState(() => _accepting = v),
          ),
        ),
        Card(
          child: SwitchListTile(
            title: const Text(
              'Weekly Schedule Enabled',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: const Text(
              'बंद रहने के दिन/समय में checkout रोकने के लिए ON करें',
            ),
            value: _scheduleEnabled,
            onChanged: (v) => setState(() => _scheduleEnabled = v),
          ),
        ),
        const SizedBox(height: 8),
        ..._days.map(
          (day) => Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      day,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      _enabled[day]!
                          ? 'इस दिन ऑर्डर खुल सकते हैं'
                          : 'इस दिन पूरे दिन बंद',
                    ),
                    value: _enabled[day]!,
                    onChanged: (v) => setState(() => _enabled[day] = v),
                  ),
                  if (_enabled[day]!)
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _pickTime(day, true),
                            icon: const Icon(Icons.login),
                            label: Text('Open ${_open[day]!.format(context)}'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _pickTime(day, false),
                            icon: const Icon(Icons.logout),
                            label: Text(
                              'Close ${_close[day]!.format(context)}',
                            ),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _messageController,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'Customer को बंद होने पर दिखने वाला संदेश',
            prefixIcon: Icon(Icons.message_outlined),
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 52,
          child: FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.save),
            label: Text(_saving ? 'Saving…' : 'Save Order Controls'),
          ),
        ),
      ],
    );
  }
}

// ============================================================
// CEO-ONLY MANAGER / FRANCHISE REGISTRATION
// Uses callable Cloud Functions and private Firebase Storage paths.
// ============================================================
class ManagerRegistrationPage extends StatefulWidget {
  const ManagerRegistrationPage({super.key});
  @override
  State<ManagerRegistrationPage> createState() =>
      _ManagerRegistrationPageState();
}

class _ManagerRegistrationPageState extends State<ManagerRegistrationPage> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _phone = TextEditingController();
  final _aadhaarLast4 = TextEditingController();
  final _pan = TextEditingController();
  final _fatherName = TextEditingController();
  final _fatherAadhaarLast4 = TextEditingController();
  final _address = TextEditingController();
  final _branchName = TextEditingController();
  final _lat = TextEditingController();
  final _lng = TextEditingController();
  final Map<String, XFile?> _documents = {
    'aadhaar': null,
    'pan': null,
    'fatherAadhaar': null,
    'residentialCertificate': null,
  };
  double _radius = 4;
  bool _saving = false;
  String? _createdManagerId;
  String? _createdBranchId;
  String? _resetLink;

  @override
  void dispose() {
    for (final c in [
      _name,
      _email,
      _password,
      _phone,
      _aadhaarLast4,
      _pan,
      _fatherName,
      _fatherAadhaarLast4,
      _address,
      _branchName,
      _lat,
      _lng,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickDocument(String key) async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
      maxWidth: 1800,
    );
    if (picked != null && mounted) setState(() => _documents[key] = picked);
  }

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? 'यह जानकारी भरें' : null;

  Future<void> _createManager() async {
    if (!_formKey.currentState!.validate()) return;
    final lat = double.tryParse(_lat.text.trim());
    final lng = double.tryParse(_lng.text.trim());
    final email = _email.text.trim().toLowerCase();
    final password = _password.text;
    if (lat == null ||
        lng == null ||
        lat < -90 ||
        lat > 90 ||
        lng < -180 ||
        lng > 180) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Branch का सही latitude और longitude भरें।'),
        ),
      );
      return;
    }
    if (_radius < 1 || _radius > 4) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Delivery radius 1 से 4 KM तक रखें।')),
      );
      return;
    }
    if (password.length < 8) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Password कम से कम 8 characters का रखें।'),
        ),
      );
      return;
    }
    setState(() => _saving = true);
    FirebaseApp? secondaryApp;
    User? createdUser;
    try {
      // Use a secondary Firebase app so creating the manager account does not log the CEO out.
      try {
        secondaryApp = Firebase.app('flashcartManagerCreator');
      } on FirebaseException {
        secondaryApp = await Firebase.initializeApp(
          name: 'flashcartManagerCreator',
          options: DefaultFirebaseOptions.currentPlatform,
        );
      }
      final secondaryAuth = FirebaseAuth.instanceFor(app: secondaryApp);
      final credential = await secondaryAuth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
      createdUser = credential.user;
      if (createdUser == null)
        throw Exception('Firebase ने Manager UID नहीं दिया।');
      final uid = createdUser.uid;
      final db = FirebaseFirestore.instance;
      final counterRef = db.collection('systemCounters').doc('managerId');
      final branchRef = db.collection('branches').doc();
      String managerId = '';
      await db.runTransaction((transaction) async {
        final counterSnap = await transaction.get(counterRef);
        final counterData = counterSnap.data() ?? <String, dynamic>{};
        final current =
            (counterData['value'] as num?)?.toInt() ??
            (counterData['val'] as num?)?.toInt() ??
            0;
        final next = current + 1;
        managerId = 'FCM-${next.toString().padLeft(6, '0')}';
        transaction.set(counterRef, {
          'value': next,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        transaction.set(branchRef, {
          'branchId': branchRef.id,
          'branchName': _branchName.text.trim().isEmpty
              ? '${_name.text.trim()} Store'
              : _branchName.text.trim(),
          'storeName': _branchName.text.trim().isEmpty
              ? '${_name.text.trim()} Store'
              : _branchName.text.trim(),
          'managerUid': uid,
          'managerId': managerId,
          'latitude': lat,
          'longitude': lng,
          'locationSet': true,
          'serviceRadiusKm': _radius,
          'active': true,
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
        transaction.set(db.collection('managers').doc(uid), {
          'uid': uid,
          'managerId': managerId,
          'name': _name.text.trim(),
          'email': email,
          'phone': _phone.text.trim(),
          'aadhaarLast4': _aadhaarLast4.text.trim(),
          'pan': _pan.text.trim().toUpperCase(),
          'fatherName': _fatherName.text.trim(),
          'fatherAadhaarLast4': _fatherAadhaarLast4.text.trim(),
          'residentialAddress': _address.text.trim(),
          'branchId': branchRef.id,
          'branchName': _branchName.text.trim().isEmpty
              ? '${_name.text.trim()} Store'
              : _branchName.text.trim(),
          'active': true,
          'role': 'manager',
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
        // Admin App login checks admins/{uid}; create this profile too.
        transaction.set(db.collection('admins').doc(uid), {
          'uid': uid,
          'name': _name.text.trim(),
          'email': email,
          'phone': _phone.text.trim(),
          'role': 'admin',
          'active': true,
          'branchId': branchRef.id,
          'storeId': branchRef.id,
          'branchName': _branchName.text.trim().isEmpty
              ? '${_name.text.trim()} Store'
              : _branchName.text.trim(),
          'storeName': _branchName.text.trim().isEmpty
              ? '${_name.text.trim()} Store'
              : _branchName.text.trim(),
          'latitude': lat,
          'longitude': lng,
          'serviceRadiusKm': _radius,
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      });
      final paths = <String, String>{};
      for (final entry in _documents.entries) {
        final file = entry.value;
        if (file == null) continue;
        final path =
            'managerDocuments/$uid/${entry.key}_${DateTime.now().millisecondsSinceEpoch}.jpg';
        await FirebaseStorage.instance
            .ref(path)
            .putFile(
              File(file.path),
              SettableMetadata(contentType: 'image/jpeg'),
            );
        paths[entry.key] = path;
      }
      if (paths.isNotEmpty) {
        await db.collection('managers').doc(uid).update({
          'documents': paths,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }
      await secondaryAuth.signOut();
      if (!mounted) return;
      setState(() {
        _createdManagerId = managerId;
        _createdBranchId = branchRef.id;
        _resetLink = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Admin login और Store बन गए। अब Admin अपने Email/Password से Admin App में login कर सकता है।',
          ),
        ),
      );
    } on FirebaseAuthException catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Manager account नहीं बना: ${e.message ?? e.code}'),
          ),
        );
    } catch (e) {
      // If Firestore profile creation fails after Auth account creation, remove the orphan account.
      try {
        if (createdUser != null) await createdUser!.delete();
      } catch (_) {}
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Registration पूरी नहीं हुई: $e', maxLines: 4),
          ),
        );
    } finally {
      try {
        if (secondaryApp != null)
          await FirebaseAuth.instanceFor(app: secondaryApp).signOut();
      } catch (_) {}
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _field(
    TextEditingController c,
    String label, {
    TextInputType keyboard = TextInputType.text,
    String? Function(String?)? validator,
    int maxLines = 1,
    bool obscureText = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextFormField(
      controller: c,
      keyboardType: keyboard,
      validator: validator,
      obscureText: obscureText,
      maxLines: maxLines,
      decoration: InputDecoration(
        labelText: label,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
  );

  Widget _documentTile(String key, String title) {
    final file = _documents[key];
    return Card(
      child: ListTile(
        leading: Icon(
          file == null ? Icons.upload_file_rounded : Icons.check_circle_rounded,
          color: file == null ? orange : green,
        ),
        title: Text(title),
        subtitle: Text(file?.name ?? 'Optional: फोटो चुनें'),
        trailing: IconButton(
          onPressed: _saving ? null : () => _pickDocument(key),
          icon: const Icon(Icons.photo_library_outlined),
        ),
        onTap: _saving ? null : () => _pickDocument(key),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Admin / Store Registration',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 6),
        const Text(
          'Admin login और Store CEO App से बनाएं। Store ID अपने-आप बनेगी; radius अधिकतम 4 KM है.',
          style: TextStyle(color: grey),
        ),
        const SizedBox(height: 16),
        if (_createdManagerId != null)
          Card(
            color: Colors.green.shade50,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Admin और Store बनाए गए ✓',
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
                  ),
                  SelectableText('Manager ID: $_createdManagerId'),
                  SelectableText('Branch ID: $_createdBranchId'),
                  const Text(
                    'Login Email और Password वही हैं जो registration form में दर्ज किए गए थे। Password सुरक्षित रूप से Manager को दें।',
                  ),
                  if (_resetLink != null) ...[
                    const SizedBox(height: 8),
                    const Text(
                      'Password set करने के लिए यह reset link Manager को सुरक्षित तरीके से दें:',
                    ),
                    SelectableText(_resetLink!),
                  ],
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () {
                      setState(() {
                        _createdManagerId = null;
                        _createdBranchId = null;
                        _resetLink = null;
                      });
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('Add another manager'),
                  ),
                ],
              ),
            ),
          ),
        Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _field(_name, 'Manager का पूरा नाम', validator: _required),
              _field(
                _email,
                'Manager Gmail / Email',
                keyboard: TextInputType.emailAddress,
                validator: _required,
              ),
              _field(
                _password,
                'Manager Login Password (कम से कम 8 characters)',
                validator: (v) => (v ?? '').length < 8
                    ? 'कम से कम 8 characters का password भरें'
                    : null,
                obscureText: true,
              ),
              _field(
                _phone,
                'मोबाइल नंबर',
                keyboard: TextInputType.phone,
                validator: _required,
              ),
              _field(
                _aadhaarLast4,
                'Manager Aadhaar के अंतिम 4 अंक (पूरा Aadhaar न लिखें)',
                keyboard: TextInputType.number,
                validator: (v) =>
                    (v ?? '').isEmpty || RegExp(r'^\d{4}$').hasMatch(v!)
                    ? null
                    : 'केवल 4 अंक भरें',
              ),
              _field(_pan, 'PAN Number (optional)'),
              _field(_fatherName, 'पिता का नाम'),
              _field(
                _fatherAadhaarLast4,
                'पिता के Aadhaar के अंतिम 4 अंक (optional)',
                keyboard: TextInputType.number,
                validator: (v) =>
                    (v ?? '').isEmpty || RegExp(r'^\d{4}$').hasMatch(v!)
                    ? null
                    : 'केवल 4 अंक भरें',
              ),
              _field(
                _address,
                'निवास प्रमाणपत्र के अनुसार पता',
                validator: _required,
                maxLines: 2,
              ),
              _field(
                _branchName,
                'Branch / Franchise का नाम (खाली छोड़ने पर auto name)',
              ),
              _field(
                _lat,
                'Branch Latitude',
                keyboard: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
                validator: _required,
              ),
              _field(
                _lng,
                'Branch Longitude',
                keyboard: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
                validator: _required,
              ),
              Text(
                'Delivery Radius: ${_radius.toStringAsFixed(0)} KM (maximum 4 KM)',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              Slider(
                value: _radius,
                min: 1,
                max: 4,
                divisions: 3,
                label: '${_radius.toStringAsFixed(0)} KM',
                onChanged: _saving ? null : (v) => setState(() => _radius = v),
              ),
              const SizedBox(height: 8),
              const Text(
                'दस्तावेज़ की फोटो (Firebase Storage में private path पर upload होगी)',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
              _documentTile('aadhaar', 'Manager Aadhaar Card'),
              _documentTile('pan', 'Manager PAN Card'),
              _documentTile('fatherAadhaar', 'Father Aadhaar Card'),
              _documentTile(
                'residentialCertificate',
                'Residential Certificate',
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _saving || _createdManagerId != null
                    ? null
                    : _createManager,
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.person_add_alt_1_rounded),
                label: Text(
                  _saving
                      ? 'Manager बनाया जा रहा है…'
                      : 'CREATE MANAGER & BRANCH',
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: orange,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'सुरक्षा: पूरा Aadhaar number collect न करें। दस्तावेज़ केवल अधिकृत CEO account से upload/read करने के लिए Storage rules configure करें.',
                style: TextStyle(color: grey, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ============================================================
// CEO CUSTOMER SERVICE AREA / DISTANCE LIMIT
// Firestore: appConfig/serviceArea
// ============================================================
class CeoServiceAreaPage extends StatefulWidget {
  const CeoServiceAreaPage({super.key});
  @override
  State<CeoServiceAreaPage> createState() => _CeoServiceAreaPageState();
}

class _CeoServiceAreaPageState extends State<CeoServiceAreaPage> {
  final _lat = TextEditingController();
  final _lng = TextEditingController();
  String? _branchId;
  Map<String, dynamic> _branch = {};
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _branches = [];
  double _radius = 4;
  bool _enabled = true, _loading = true, _saving = false;

  @override
  void initState() {
    super.initState();
    _loadBranches();
  }

  @override
  void dispose() {
    _lat.dispose();
    _lng.dispose();
    super.dispose();
  }

  Future<void> _loadBranches() async {
    setState(() => _loading = true);
    try {
      final snap = await FirebaseFirestore.instance
          .collection('branches')
          .get(const GetOptions(source: Source.server));
      _branches = snap.docs;
      if (_branchId != null && _branches.any((d) => d.id == _branchId)) {
        _selectBranch(_branchId!);
      } else if (_branches.isNotEmpty) {
        _selectBranch(_branches.first.id);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Branches load नहीं हुईं: $e')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _selectBranch(String id) {
    final doc = _branches.firstWhere((d) => d.id == id);
    final d = doc.data();
    _branchId = id;
    _branch = d;
    _lat.text = (d['latitude'] ?? d['branchLatitude'] ?? '').toString();
    _lng.text = (d['longitude'] ?? d['branchLongitude'] ?? '').toString();
    final r = d['serviceRadiusKm'];
    _radius = r is num ? r.toDouble().clamp(1.0, 4.0) : 4.0;
    _enabled = d['locationSet'] != false && d['active'] != false;
  }

  Future<void> _save() async {
    if (_branchId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('पहले Branch बनाएं, फिर यहाँ चुनें।')),
      );
      return;
    }
    final lat = double.tryParse(_lat.text.trim());
    final lng = double.tryParse(_lng.text.trim());
    if (lat == null ||
        lng == null ||
        lat < -90 ||
        lat > 90 ||
        lng < -180 ||
        lng > 180) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('सही latitude और longitude भरें।')),
      );
      return;
    }
    if (_radius < 1 || _radius > 4) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Radius 1 से 4 KM के बीच रखें।')),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final name =
          (_branch['branchName'] ??
                  _branch['name'] ??
                  _branch['displayName'] ??
                  'FlashCart Branch')
              .toString();
      await FirebaseFirestore.instance
          .collection('branches')
          .doc(_branchId)
          .set({
            'branchName': name,
            'latitude': lat,
            'longitude': lng,
            'branchLatitude': lat,
            'branchLongitude': lng,
            'serviceRadiusKm': _radius,
            'locationSet': _enabled,
            'active': _branch['active'] == false ? false : true,
            'locationUpdatedAt': FieldValue.serverTimestamp(),
            'serviceAreaUpdatedAt': FieldValue.serverTimestamp(),
            'serviceAreaUpdatedBy':
                FirebaseAuth.instance.currentUser?.uid ?? '',
          }, SetOptions(merge: true));
      await _loadBranches();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Branch की location और radius save हो गई ✓'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: orange));
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Manager / Branch Location & Radius',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 8),
        const Text(
          'हर Branch की अपनी delivery location चुनें। Customer का पता चुनी हुई Branch से अधिकतम 4 KM के अंदर होना चाहिए.',
          style: TextStyle(color: grey),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _branchId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Manager / Branch चुनें',
                ),
                items: _branches.map((d) {
                  final x = d.data();
                  final label =
                      (x['branchName'] ?? x['name'] ?? x['displayName'] ?? d.id)
                          .toString();
                  return DropdownMenuItem(
                    value: d.id,
                    child: Text(label, overflow: TextOverflow.ellipsis),
                  );
                }).toList(),
                onChanged: _saving
                    ? null
                    : (id) {
                        if (id == null) return;
                        setState(() => _selectBranch(id));
                      },
              ),
            ),
            IconButton(
              onPressed: _saving ? null : _loadBranches,
              tooltip: 'Refresh branches',
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        if (_branches.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(14),
              child: Text(
                'कोई Branch record नहीं मिला। पहले Manager/Branch creation flow में branch document बनना चाहिए; document ID manually भरने की जरूरत नहीं, dropdown में record आने पर चुनें।',
              ),
            ),
          ),
        const SizedBox(height: 12),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('इस Branch की location service चालू रखें'),
          value: _enabled,
          onChanged: _saving ? null : (v) => setState(() => _enabled = v),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _lat,
          keyboardType: const TextInputType.numberWithOptions(
            decimal: true,
            signed: true,
          ),
          decoration: const InputDecoration(labelText: 'Branch Latitude'),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _lng,
          keyboardType: const TextInputType.numberWithOptions(
            decimal: true,
            signed: true,
          ),
          decoration: const InputDecoration(labelText: 'Branch Longitude'),
        ),
        const SizedBox(height: 16),
        Text(
          'Maximum delivery radius: ${_radius.toStringAsFixed(0)} KM',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        Slider(
          value: _radius,
          min: 1,
          max: 4,
          divisions: 3,
          label: '${_radius.toStringAsFixed(0)} KM',
          onChanged: _saving ? null : (v) => setState(() => _radius = v),
        ),
        const Text(
          '1 KM • 2 KM • 3 KM • 4 KM (maximum)',
          style: TextStyle(color: grey),
        ),
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: _saving ? null : _save,
          icon: const Icon(Icons.save),
          label: Text(_saving ? 'Saving…' : 'Save Branch Service Area'),
        ),
      ],
    );
  }
}

// ============================================================
// CEO-ONLY BRANCH SALES & PERFORMANCE RANKING
// Uses branchId/branchName written into customer orders.
// ============================================================
class BranchSalesAnalyticsPage extends StatelessWidget {
  const BranchSalesAnalyticsPage({super.key});

  double _amount(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) {
      return double.tryParse(value.replaceAll(RegExp(r'[^0-9.\-]'), '')) ?? 0;
    }
    return 0;
  }

  double _orderAmount(Map<String, dynamic> data) {
    for (final key in const [
      'totalPrice',
      'totalAmount',
      'grandTotal',
      'orderTotal',
      'payableAmount',
      'amount',
      'total',
    ]) {
      final value = _amount(data[key]);
      if (value > 0) return value;
    }
    final items = data['items'] ?? data['orderItems'] ?? data['products'];
    if (items is List) {
      var total = 0.0;
      for (final raw in items) {
        if (raw is! Map) continue;
        final price = _amount(
          raw['sellingPrice'] ?? raw['price'] ?? raw['unitPrice'],
        );
        final quantity = _amount(raw['quantity'] ?? raw['qty'] ?? 1);
        total += price * (quantity <= 0 ? 1 : quantity);
      }
      total += _amount(data['deliveryFee'] ?? data['deliveryCharge']);
      total -= _amount(data['discountAmount'] ?? data['discount_amount']);
      return total > 0 ? total : 0;
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('orders').snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                'Branch analytics load नहीं हुआ।\n${snapshot.error}',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator(color: orange));
        }

        final grouped = <String, Map<String, dynamic>>{};
        for (final doc in snapshot.data!.docs) {
          final data = doc.data();
          final branchId = (data['branchId'] ?? '').toString().trim();
          final branchName = (data['branchName'] ?? '').toString().trim();
          final key = branchId.isNotEmpty
              ? branchId
              : (branchName.isNotEmpty ? 'name:$branchName' : 'unassigned');
          final row = grouped.putIfAbsent(
            key,
            () => {
              'branchId': branchId,
              'branchName': branchName.isNotEmpty
                  ? branchName
                  : (branchId.isNotEmpty
                        ? 'Branch $branchId'
                        : 'Branch not recorded'),
              'orders': 0,
              'delivered': 0,
              'pending': 0,
              'cancelled': 0,
              'sales': 0.0,
              'allOrderValue': 0.0,
            },
          );
          row['orders'] = (row['orders'] as int) + 1;
          final status = (data['status'] ?? '').toString().toLowerCase().trim();
          if (status == 'delivered') {
            row['delivered'] = (row['delivered'] as int) + 1;
            row['sales'] = (row['sales'] as double) + _orderAmount(data);
          } else if (status.contains('cancel')) {
            row['cancelled'] = (row['cancelled'] as int) + 1;
          } else {
            row['pending'] = (row['pending'] as int) + 1;
          }
          row['allOrderValue'] =
              (row['allOrderValue'] as double) + _orderAmount(data);
        }
        final rows = grouped.values.toList()
          ..sort(
            (a, b) => (b['sales'] as double).compareTo(a['sales'] as double),
          );
        final totalSales = rows.fold<double>(
          0,
          (sum, row) => sum + (row['sales'] as double),
        );
        final delivered = rows.fold<int>(
          0,
          (sum, row) => sum + (row['delivered'] as int),
        );
        final totalOrders = rows.fold<int>(
          0,
          (sum, row) => sum + (row['orders'] as int),
        );

        return RefreshIndicator(
          onRefresh: () async {
            await FirebaseFirestore.instance
                .collection('orders')
                .get(const GetOptions(source: Source.server));
          },
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'Branch Sales & Performance',
                style: TextStyle(fontSize: 25, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 6),
              const Text(
                'CEO overview: branch-wise delivered sales, order volume और performance ranking. सबसे ज्यादा sale वाली Branch सबसे ऊपर है।',
                style: TextStyle(color: grey),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _branchMetric(
                      'Delivered Sales',
                      '₹${totalSales.toStringAsFixed(2)}',
                      Icons.currency_rupee_rounded,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _branchMetric(
                      'Delivered Orders',
                      '$delivered',
                      Icons.check_circle_outline_rounded,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _branchMetric(
                'Total Orders',
                '$totalOrders',
                Icons.shopping_bag_outlined,
              ),
              const SizedBox(height: 18),
              const Text(
                'Branch Ranking — Highest Sale First',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 10),
              if (rows.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(18),
                    child: Text('अभी कोई order data उपलब्ध नहीं है।'),
                  ),
                )
              else
                ...rows.asMap().entries.map((entry) {
                  final rank = entry.key + 1;
                  final row = entry.value;
                  final sale = row['sales'] as double;
                  final double share = totalSales > 0
                      ? (sale / totalSales).clamp(0.0, 1.0).toDouble()
                      : 0.0;
                  return Card(
                    margin: const EdgeInsets.only(bottom: 10),
                    child: Padding(
                      padding: const EdgeInsets.all(15),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              CircleAvatar(
                                backgroundColor: rank == 1
                                    ? const Color(0xFFFFF0C2)
                                    : lightOrange,
                                child: Text(
                                  '$rank',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w900,
                                    color: rank == 1
                                        ? const Color(0xFF8A5A00)
                                        : orange,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      row['branchName'].toString(),
                                      style: const TextStyle(
                                        fontSize: 17,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                    if ((row['branchId'] as String).isNotEmpty)
                                      Text(
                                        'Branch ID: ${row['branchId']}',
                                        style: const TextStyle(
                                          color: grey,
                                          fontSize: 11,
                                        ),
                                      ),
                                    const SizedBox(height: 4),
                                    Text(
                                      'Delivered sales: ₹${sale.toStringAsFixed(2)}',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                        color: green,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (rank == 1)
                                const Icon(
                                  Icons.emoji_events_rounded,
                                  color: Color(0xFFE0A000),
                                  size: 28,
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: LinearProgressIndicator(
                              value: share,
                              minHeight: 7,
                              backgroundColor: lightOrange,
                              color: rank == 1
                                  ? const Color(0xFFE0A000)
                                  : orange,
                            ),
                          ),
                          const SizedBox(height: 9),
                          Wrap(
                            spacing: 14,
                            runSpacing: 6,
                            children: [
                              Text(
                                'Orders: ${row['orders']}',
                                style: const TextStyle(color: grey),
                              ),
                              Text(
                                'Delivered: ${row['delivered']}',
                                style: const TextStyle(color: grey),
                              ),
                              Text(
                                'Pending: ${row['pending']}',
                                style: const TextStyle(color: grey),
                              ),
                              Text(
                                'Cancelled: ${row['cancelled']}',
                                style: const TextStyle(color: grey),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              const SizedBox(height: 8),
              const Text(
                'Sales calculation: केवल Delivered orders की राशि Branch sales में गिनी जाती है। पुराने orders जिनमें branchId/branchName नहीं है, वे “Branch not recorded” में दिखेंगे।',
                style: TextStyle(color: grey, fontSize: 12),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _branchMetric(String title, String value, IconData icon) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: orange),
            const SizedBox(height: 8),
            Text(title, style: const TextStyle(color: grey, fontSize: 12)),
            const SizedBox(height: 4),
            Text(
              value,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// CEO — BANK DETAILS REVIEW (ADMINS, MANAGERS, DELIVERY PARTNERS)
// ============================================================
class CeoPartnerBankVerificationPage extends StatefulWidget {
  const CeoPartnerBankVerificationPage({super.key});

  @override
  State<CeoPartnerBankVerificationPage> createState() =>
      _CeoPartnerBankVerificationPageState();
}

class _CeoPartnerBankVerificationPageState
    extends State<CeoPartnerBankVerificationPage> {
  final FirebaseFirestore db = FirebaseFirestore.instance;
  String? branchId;
  String profileType = 'admins';
  bool reviewBusy = false;

  void _msg(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _review(String collectionName, String uid, bool approve) async {
    final note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          approve ? 'Bank details approve करें?' : 'Bank details reject करें?',
        ),
        content: TextField(
          controller: note,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'CEO note (optional)',
            hintText: 'Reject करने पर कारण लिखें',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: approve ? green : red,
            ),
            child: Text(approve ? 'Approve' : 'Reject'),
          ),
        ],
      ),
    );

    if (ok != true) {
      note.dispose();
      return;
    }

    setState(() => reviewBusy = true);
    try {
      await db.collection(collectionName).doc(uid).update({
        'payoutBank.verificationStatus': approve ? 'Verified' : 'Rejected',
        'payoutBank.verified': approve,
        'payoutBank.verifiedAt': approve ? FieldValue.serverTimestamp() : null,
        'payoutBank.verifiedBy': FirebaseAuth.instance.currentUser?.uid ?? '',
        'payoutBank.ceoNote': note.text.trim(),
        'payoutBank.reviewedAt': FieldValue.serverTimestamp(),
        'bankVerificationStatus': approve ? 'Verified' : 'Rejected',
        'updatedAt': FieldValue.serverTimestamp(),
      });
      _msg(
        approve
            ? 'Bank details approve हो गईं।'
            : 'Bank details reject हो गईं।',
      );
    } catch (e) {
      _msg('Review save नहीं हुआ: $e');
    } finally {
      note.dispose();
      if (mounted) setState(() => reviewBusy = false);
    }
  }

  Future<String> _privateDocumentUrl(String path) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception('CEO login आवश्यक है।');

    final token = await user.getIdToken(true);
    if (token == null) throw Exception('Firebase token नहीं मिला।');

    const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
    const publishableKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
    if (supabaseUrl.isEmpty || publishableKey.isEmpty) {
      throw Exception(
        'Private document देखने के लिए SUPABASE_URL और SUPABASE_PUBLISHABLE_KEY build configuration सेट करें।',
      );
    }

    final response = await http.post(
      Uri.parse('$supabaseUrl/functions/v1/ceo-bank-document-url'),
      headers: {
        'apikey': publishableKey,
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'path': path}),
    );
    final result = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200 || result['signedUrl'] == null) {
      throw Exception(result['error'] ?? 'Private document नहीं खुला।');
    }
    return result['signedUrl'].toString();
  }

  Future<void> _openDocument(String path) async {
    if (path.trim().isEmpty) {
      _msg('Document path नहीं मिला।');
      return;
    }
    try {
      final url = path.startsWith('https://') || path.startsWith('http://')
          ? path
          : await _privateDocumentUrl(path);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Private Bank Document',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 520),
                  child: Image.network(
                    url,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('Document load नहीं हुआ।'),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Close'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } catch (e) {
      _msg('Document नहीं खुला: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: db.collection('branches').snapshots(),
      builder: (context, branchSnapshot) {
        if (branchSnapshot.hasError) {
          return Center(
            child: Text('Branches load error: ${branchSnapshot.error}'),
          );
        }
        if (!branchSnapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final branches = branchSnapshot.data!.docs;
        if (branches.isEmpty) {
          return const Center(child: Text('कोई branch नहीं मिली।'));
        }
        if (branchId == null || !branches.any((b) => b.id == branchId)) {
          branchId = branches.first.id;
        }

        return ListView(
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
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.account_balance_rounded,
                    color: Colors.white,
                    size: 32,
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Bank Details & Verification',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Admin / Store Owner, Manager और Delivery Partner के bank details तथा cheque/passbook document जाँचें।',
                    style: TextStyle(color: Colors.white),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              value: branchId,
              decoration: const InputDecoration(
                labelText: 'Branch चुनें',
                border: OutlineInputBorder(),
              ),
              items: branches.map((b) {
                final d = b.data();
                return DropdownMenuItem<String>(
                  value: b.id,
                  child: Text(
                    (d['branchName'] ?? d['storeName'] ?? b.id).toString(),
                    overflow: TextOverflow.ellipsis,
                  ),
                );
              }).toList(),
              onChanged: (value) => setState(() => branchId = value),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: profileType,
              decoration: const InputDecoration(
                labelText: 'किसके bank details देखने हैं?',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(
                  value: 'admins',
                  child: Text('Admin / Store Owner'),
                ),
                DropdownMenuItem(value: 'managers', child: Text('Manager')),
                DropdownMenuItem(
                  value: 'deliveryPartners',
                  child: Text('Delivery Partner'),
                ),
              ],
              onChanged: reviewBusy
                  ? null
                  : (value) => setState(() => profileType = value ?? 'admins'),
            ),
            const SizedBox(height: 14),
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: db
                  .collection(profileType)
                  .where('branchId', isEqualTo: branchId)
                  .snapshots(),
              builder: (context, profileSnapshot) {
                if (profileSnapshot.hasError) {
                  return Text('Profiles load error: ${profileSnapshot.error}');
                }
                if (!profileSnapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                final docs = profileSnapshot.data!.docs.where((doc) {
                  final raw = doc.data()['payoutBank'];
                  return raw is Map && raw.isNotEmpty;
                }).toList();

                if (docs.isEmpty) {
                  return const Card(
                    child: Padding(
                      padding: EdgeInsets.all(18),
                      child: Text(
                        'इस branch में अभी कोई bank details submit नहीं हुई हैं।',
                      ),
                    ),
                  );
                }

                return Column(
                  children: docs.map((doc) {
                    final d = doc.data();
                    final bank = Map<String, dynamic>.from(
                      d['payoutBank'] is Map
                          ? d['payoutBank']
                          : <String, dynamic>{},
                    );
                    final status = (bank['verificationStatus'] ?? 'Pending')
                        .toString();
                    final verified =
                        status == 'Verified' && bank['verified'] == true;
                    final name =
                        (d['name'] ??
                                d['fullName'] ??
                                d['storeName'] ??
                                (profileType == 'admins'
                                    ? 'Admin / Store Owner'
                                    : profileType == 'managers'
                                    ? 'Manager'
                                    : 'Delivery Partner'))
                            .toString();
                    final account = (bank['accountNumber'] ?? '').toString();
                    final documentPath =
                        (bank['documentPath'] ?? bank['documentUrl'] ?? '')
                            .toString();

                    return Card(
                      margin: const EdgeInsets.only(bottom: 12),
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
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: verified
                                        ? Colors.green.shade50
                                        : lightOrange,
                                    borderRadius: BorderRadius.circular(18),
                                  ),
                                  child: Text(
                                    status.toUpperCase(),
                                    style: TextStyle(
                                      color: verified
                                          ? green
                                          : (status == 'Rejected'
                                                ? red
                                                : orange),
                                      fontSize: 10,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Branch: ${(d['branchName'] ?? d['storeName'] ?? branchId ?? '—')}',
                            ),
                            Text(
                              'Account holder: ${bank['accountHolderName'] ?? bank['accountHolder'] ?? '—'}',
                            ),
                            SelectableText(
                              'Account number: ${account.isEmpty ? 'Not provided' : account}',
                            ),
                            Text('Bank: ${bank['bankName'] ?? '—'}'),
                            Text(
                              'IFSC: ${bank['ifsc'] ?? '—'} • UPI: ${bank['upiId'] ?? '—'}',
                            ),
                            if (documentPath.isNotEmpty)
                              Align(
                                alignment: Alignment.centerLeft,
                                child: TextButton.icon(
                                  onPressed: () => _openDocument(documentPath),
                                  icon: const Icon(Icons.description_outlined),
                                  label: Text(
                                    'View ${bank['documentName'] ?? 'cheque / passbook'}',
                                  ),
                                ),
                              )
                            else
                              const Text('Cheque/passbook document नहीं मिला।'),
                            if ((bank['ceoNote'] ?? '').toString().isNotEmpty)
                              Text('CEO note: ${bank['ceoNote']}'),
                            if (!verified)
                              Wrap(
                                spacing: 8,
                                children: [
                                  OutlinedButton.icon(
                                    onPressed: reviewBusy
                                        ? null
                                        : () => _review(
                                            profileType,
                                            doc.id,
                                            false,
                                          ),
                                    icon: const Icon(Icons.close),
                                    label: const Text('Reject'),
                                  ),
                                  FilledButton.icon(
                                    onPressed: reviewBusy
                                        ? null
                                        : () => _review(
                                            profileType,
                                            doc.id,
                                            true,
                                          ),
                                    icon: const Icon(Icons.verified_rounded),
                                    label: const Text('Approve Bank'),
                                    style: FilledButton.styleFrom(
                                      backgroundColor: green,
                                    ),
                                  ),
                                ],
                              )
                            else
                              const Row(
                                children: [
                                  Icon(Icons.verified, color: Colors.green),
                                  SizedBox(width: 6),
                                  Text('Bank details approved'),
                                ],
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
        );
      },
    );
  }
}

// ============================================================
// WEEKLY PAYOUT + BRANCH ADMIN COMMISSION / INCENTIVES
// Weekly windows use Monday 00:00 through next Monday 00:00.
// Commission applies only to delivered orders; cancelled orders are excluded.
// ============================================================
class CeoWeeklyPayoutCommissionPage extends StatefulWidget {
  const CeoWeeklyPayoutCommissionPage({super.key});
  @override
  State<CeoWeeklyPayoutCommissionPage> createState() =>
      _CeoWeeklyPayoutCommissionPageState();
}

class _CeoWeeklyPayoutCommissionPageState
    extends State<CeoWeeklyPayoutCommissionPage> {
  String? selectedBranchId;
  final commissionController = TextEditingController(text: '0');
  final targetSalesController = TextEditingController(text: '50000');
  final targetBonusController = TextEditingController(text: '500');
  bool saving = false;

  @override
  void dispose() {
    commissionController.dispose();
    targetSalesController.dispose();
    targetBonusController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings(String branchId) async {
    final snap = await FirebaseFirestore.instance
        .collection('branchCommissionSettings')
        .doc(branchId)
        .get();
    final d = snap.data() ?? {};
    commissionController.text = flashMoney(d['commissionPercent']).toString();
    final targets = d['weeklyTargets'];
    if (targets is List && targets.isNotEmpty && targets.first is Map) {
      targetSalesController.text = flashMoney(targets.first['salesAmount'])
          .toString();
      targetBonusController.text = flashMoney(targets.first['incentiveAmount'])
          .toString();
    } else {
      targetSalesController.text = '50000';
      targetBonusController.text = '500';
    }
    if (mounted) setState(() {});
  }

  Future<void> _saveSettings(
    String branchId,
    Map<String, dynamic> branch,
  ) async {
    final rate = double.tryParse(commissionController.text.trim()) ?? -1;
    final target = double.tryParse(targetSalesController.text.trim()) ?? -1;
    final bonus = double.tryParse(targetBonusController.text.trim()) ?? -1;
    if (rate < 0 || rate > 100 || target < 0 || bonus < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Commission 0–100% और target/bonus सही भरें.'),
        ),
      );
      return;
    }
    setState(() => saving = true);
    try {
      await FirebaseFirestore.instance
          .collection('branchCommissionSettings')
          .doc(branchId)
          .set({
            'branchId': branchId,
            'branchName':
                (branch['branchName'] ?? branch['storeName'] ?? 'Branch')
                    .toString(),
            'commissionPercent': rate,
            'weeklyTargets': [
              {'salesAmount': target, 'incentiveAmount': bonus},
            ],
            'updatedAt': FieldValue.serverTimestamp(),
            'updatedBy': FirebaseAuth.instance.currentUser?.uid ?? '',
          }, SetOptions(merge: true));
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Branch commission और incentive settings save हो गईं.',
            ),
          ),
        );
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Save नहीं हुआ: $e')));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _createAdminPayout(
    String branchId,
    Map<String, dynamic> branch,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> orders,
    Map<String, dynamic> setting,
  ) async {
    final start = flashWeekStart();
    final end = flashWeekEnd();
    final delivered = orders.where((o) {
      final d = o.data();
      final dt = flashDeliveredDate(d);
      final b = (d['branchId'] ?? d['storeId'] ?? '').toString();
      return b == branchId &&
          flashDelivered(d) &&
          dt != null &&
          !dt.isBefore(start) &&
          dt.isBefore(end);
    }).toList();
    final sales = delivered.fold<double>(
      0,
      (sum, o) => sum + flashOrderSales(o.data()),
    );
    final rate = flashMoney(setting['commissionPercent']);
    final commission = sales * rate / 100;
    final targets = setting['weeklyTargets'];
    double incentive = 0;
    if (targets is List) {
      for (final raw in targets) {
        if (raw is Map && sales >= flashMoney(raw['salesAmount'])) {
          incentive = incentive > flashMoney(raw['incentiveAmount'])
              ? incentive
              : flashMoney(raw['incentiveAmount']);
        }
      }
    }
    final weekKey = flashWeekKey(start);
    final ref = FirebaseFirestore.instance
        .collection('weeklyPayouts')
        .doc('admin_${branchId}_$weekKey');
    final uid =
        (branch['adminUid'] ?? branch['managerUid'] ?? branch['uid'] ?? '')
            .toString();
    await ref.set({
      'recipientType': 'admin',
      'recipientUid': uid,
      'branchId': branchId,
      'branchName': (branch['branchName'] ?? branch['storeName'] ?? 'Branch')
          .toString(),
      'weekStart': Timestamp.fromDate(start),
      'weekEnd': Timestamp.fromDate(end),
      'weekKey': weekKey,
      'deliveredOrderCount': delivered.length,
      'deliveredSales': sales,
      'commissionPercent': rate,
      'commissionAmount': commission,
      'incentiveAmount': incentive,
      'totalEarning': commission + incentive,
      'status': 'Pending',
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Admin payout record बना: ₹${(commission + incentive).toStringAsFixed(2)}',
          ),
        ),
      );
  }

  Future<void> _payDeliveryPartner(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) async {
    final data = doc.data();
    final currentBalance = flashMoney(
      data['walletBalance'] ?? data['unpaidEarnings'] ?? 0,
    );
    if (currentBalance <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('इस Partner का कोई unpaid balance नहीं है।'),
        ),
      );
      return;
    }
    final amountController = TextEditingController(
      text: currentBalance.toStringAsFixed(2),
    );
    final referenceController = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          '${(data['name'] ?? data['fullName'] ?? 'Delivery Partner').toString()} को Payment',
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Unpaid balance: ₹${currentBalance.toStringAsFixed(2)}'),
            const SizedBox(height: 10),
            TextField(
              controller: amountController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Payment amount (₹)',
              ),
            ),
            TextField(
              controller: referenceController,
              decoration: const InputDecoration(
                labelText: 'UTR / Payment reference',
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'पहले बैंक/UPI से payment करें, फिर यहाँ confirm करें।',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Payment Confirm'),
          ),
        ],
      ),
    );
    if (ok != true) {
      amountController.dispose();
      referenceController.dispose();
      return;
    }
    final amount = flashMoney(amountController.text);
    final reference = referenceController.text.trim();
    amountController.dispose();
    referenceController.dispose();
    if (amount <= 0 || amount > currentBalance || reference.isEmpty) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('सही amount भरें और UTR/reference अनिवार्य है।'),
          ),
        );
      return;
    }
    try {
      final db = FirebaseFirestore.instance;
      final partnerRef = db.collection('deliveryPartners').doc(doc.id);
      final payoutRef = db
          .collection('weeklyPayouts')
          .doc('partner_${doc.id}_${DateTime.now().millisecondsSinceEpoch}');
      await db.runTransaction((tx) async {
        final fresh = await tx.get(partnerRef);
        if (!fresh.exists) throw StateError('Partner record नहीं मिला।');
        final freshData = fresh.data() ?? <String, dynamic>{};
        final balance = flashMoney(
          freshData['walletBalance'] ?? freshData['unpaidEarnings'] ?? 0,
        );
        if (amount > balance)
          throw StateError('Balance बदल गया है। फिर से जाँचें।');
        tx.update(partnerRef, {
          'walletBalance': balance - amount,
          'lastPayoutAt': FieldValue.serverTimestamp(),
          'lastPayoutAmount': amount,
          'updatedAt': FieldValue.serverTimestamp(),
        });
        tx.set(payoutRef, {
          'recipientType': 'deliveryPartner',
          'recipientUid': doc.id,
          'recipientName':
              (freshData['name'] ?? freshData['fullName'] ?? 'Delivery Partner')
                  .toString(),
          'phone':
              (freshData['phone'] ??
                      freshData['mobile'] ??
                      freshData['mobileNumber'] ??
                      '')
                  .toString(),
          'branchId': (freshData['branchId'] ?? '').toString(),
          'branchName':
              (freshData['branchName'] ?? freshData['storeName'] ?? '')
                  .toString(),
          'amount': amount,
          'totalEarningAtPayment': flashMoney(
            freshData['totalEarnings'] ?? freshData['earnings'] ?? 0,
          ),
          'status': 'Paid',
          'paymentReference': reference,
          'paidAt': FieldValue.serverTimestamp(),
          'paidBy': FirebaseAuth.instance.currentUser?.uid ?? '',
          'createdAt': FieldValue.serverTimestamp(),
        });
      });
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '₹${amount.toStringAsFixed(2)} payment record save हो गया।',
            ),
          ),
        );
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Payment save नहीं हुआ: $e')));
    }
  }

  Future<void> _markPaid(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) async {
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Payout को Paid mark करें?'),
        content: TextField(
          controller: c,
          decoration: const InputDecoration(
            labelText: 'Payment reference / UTR (optional)',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Mark Paid'),
          ),
        ],
      ),
    );
    if (ok != true) {
      c.dispose();
      return;
    }
    await doc.reference.set({
      'status': 'Paid',
      'paidAt': FieldValue.serverTimestamp(),
      'paidBy': FirebaseAuth.instance.currentUser?.uid ?? '',
      'paymentReference': c.text.trim(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    c.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final db = FirebaseFirestore.instance;
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: db.collection('branches').snapshots(),
      builder: (context, bs) {
        if (bs.hasError)
          return Center(child: Text('Branches load error: ${bs.error}'));
        if (!bs.hasData)
          return const Center(child: CircularProgressIndicator());
        final branches = bs.data!.docs;
        if (branches.isEmpty)
          return const Center(child: Text('कोई branch नहीं मिली.'));
        // Manual lookup avoids Firestore's firstWhere(orElse) runtime type mismatch.
        QueryDocumentSnapshot<Map<String, dynamic>> chosen = branches.first;
        for (final branchDoc in branches) {
          if (branchDoc.id == selectedBranchId) {
            chosen = branchDoc;
            break;
          }
        }
        if (selectedBranchId == null) {
          selectedBranchId = chosen.id;
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _loadSettings(chosen.id),
          );
        }
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Weekly Payout & Admin Incentives',
              style: TextStyle(fontSize: 23, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 6),
            Text(
              'Current week: ${flashWeekKey(flashWeekStart())} से ${flashWeekKey(flashWeekEnd())} तक (अंतिम तारीख शामिल नहीं)',
              style: const TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              value: chosen.id,
              decoration: const InputDecoration(
                labelText: 'Branch चुनें',
                border: OutlineInputBorder(),
              ),
              items: branches
                  .map(
                    (b) => DropdownMenuItem(
                      value: b.id,
                      child: Text(
                        (b.data()['branchName'] ??
                                b.data()['storeName'] ??
                                b.id)
                            .toString(),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (v) {
                if (v == null) return;
                setState(() => selectedBranchId = v);
                _loadSettings(v);
              },
            ),
            const SizedBox(height: 14),
            TextField(
              controller: commissionController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Admin commission (%)',
                helperText: 'केवल Delivered orders की बिक्री पर',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: targetSalesController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Weekly sales target (₹)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: targetBonusController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Target पूरा होने पर incentive (₹)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: saving
                  ? null
                  : () => _saveSettings(chosen.id, chosen.data()),
              icon: const Icon(Icons.save),
              label: Text(
                saving ? 'Saving...' : 'Save Branch Commission & Incentive',
              ),
            ),
            const SizedBox(height: 20),
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: db.collection('orders').snapshots(),
              builder: (context, os) {
                if (os.hasError) return Text('Orders error: ${os.error}');
                if (!os.hasData) return const LinearProgressIndicator();
                final settingStream = db
                    .collection('branchCommissionSettings')
                    .doc(chosen.id)
                    .snapshots();
                return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                  stream: settingStream,
                  builder: (context, ss) {
                    final setting = ss.data?.data() ?? {};
                    final start = flashWeekStart(), end = flashWeekEnd();
                    final ds = os.data!.docs.where((o) {
                      final d = o.data();
                      final dt = flashDeliveredDate(d);
                      return (d['branchId'] ?? d['storeId'] ?? '').toString() ==
                              chosen.id &&
                          flashDelivered(d) &&
                          dt != null &&
                          !dt.isBefore(start) &&
                          dt.isBefore(end);
                    }).toList();
                    final sales = ds.fold<double>(
                      0,
                      (v, o) => v + flashOrderSales(o.data()),
                    );
                    final rate = flashMoney(setting['commissionPercent']);
                    double incentive = 0;
                    final ts = setting['weeklyTargets'];
                    if (ts is List)
                      for (final t in ts) {
                        if (t is Map && sales >= flashMoney(t['salesAmount']))
                          incentive =
                              incentive > flashMoney(t['incentiveAmount'])
                              ? incentive
                              : flashMoney(t['incentiveAmount']);
                      }
                    final commission = sales * rate / 100;
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'This week — ${(chosen.data()['branchName'] ?? chosen.data()['storeName'] ?? chosen.id)}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 18,
                              ),
                            ),
                            _payoutRow('Delivered orders', '${ds.length}'),
                            _payoutRow(
                              'Eligible sales',
                              '₹${sales.toStringAsFixed(2)}',
                            ),
                            _payoutRow(
                              'Commission ($rate%)',
                              '₹${commission.toStringAsFixed(2)}',
                            ),
                            _payoutRow(
                              'Incentive',
                              '₹${incentive.toStringAsFixed(2)}',
                            ),
                            const Divider(),
                            _payoutRow(
                              'Total Admin earning',
                              '₹${(commission + incentive).toStringAsFixed(2)}',
                            ),
                            const SizedBox(height: 8),
                            FilledButton.icon(
                              onPressed: () => _createAdminPayout(
                                chosen.id,
                                chosen.data(),
                                os.data!.docs,
                                setting,
                              ),
                              icon: const Icon(Icons.receipt_long),
                              label: const Text(
                                'Create / Update this week payout record',
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
            const SizedBox(height: 20),
            const Text(
              'Weekly Payout Records',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
            ),
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: db
                  .collection('weeklyPayouts')
                  .where('recipientType', isEqualTo: 'admin')
                  .snapshots(),
              builder: (context, ps) {
                if (ps.hasError)
                  return Text('Payout history error: ${ps.error}');
                if (!ps.hasData) return const LinearProgressIndicator();
                final list = [...ps.data!.docs]
                  ..sort(
                    (a, b) =>
                        flashDate(b.data()['weekStart'])?.compareTo(
                          flashDate(a.data()['weekStart']) ?? DateTime(1970),
                        ) ??
                        0,
                  );
                if (list.isEmpty)
                  return const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('अभी कोई payout record नहीं है.'),
                  );
                return Column(
                  children: list.map((doc) {
                    final d = doc.data();
                    return Card(
                      child: ListTile(
                        title: Text(
                          '${d['branchName'] ?? d['branchId'] ?? 'Branch'} • ${d['weekKey'] ?? ''}',
                        ),
                        subtitle: Text(
                          'Sales ₹${flashMoney(d['deliveredSales']).toStringAsFixed(2)} • Commission ₹${flashMoney(d['commissionAmount']).toStringAsFixed(2)} • Incentive ₹${flashMoney(d['incentiveAmount']).toStringAsFixed(2)}\n${d['status'] ?? 'Pending'}${(d['paymentReference'] ?? '').toString().isNotEmpty ? ' • ${d['paymentReference']}' : ''}',
                        ),
                        isThreeLine: true,
                        trailing: (d['status'] ?? 'Pending') == 'Paid'
                            ? const Icon(
                                Icons.check_circle,
                                color: Colors.green,
                              )
                            : TextButton(
                                onPressed: () => _markPaid(doc),
                                child: const Text('Mark Paid'),
                              ),
                      ),
                    );
                  }).toList(),
                );
              },
            ),
            const SizedBox(height: 24),
            const Text(
              'Delivery Partner Earnings & Payment',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 5),
            const Text(
              'Total earnings lifetime total है; payment के लिए unpaid walletBalance इस्तेमाल होगा। Delivered orders के बाद app द्वारा जो earning wallet में जोड़ी गई है वही यहाँ payable होगी.',
              style: TextStyle(color: Colors.grey),
            ),
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: db.collection('deliveryPartners').snapshots(),
              builder: (context, partnersSnap) {
                if (partnersSnap.hasError)
                  return Text(
                    'Partner earnings load error: ${partnersSnap.error}',
                  );
                if (!partnersSnap.hasData)
                  return const LinearProgressIndicator();
                final partners = [...partnersSnap.data!.docs]
                  ..sort(
                    (a, b) => (a.data()['name'] ?? a.data()['fullName'] ?? '')
                        .toString()
                        .compareTo(
                          (b.data()['name'] ?? b.data()['fullName'] ?? '')
                              .toString(),
                        ),
                  );
                if (partners.isEmpty)
                  return const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('अभी कोई delivery partner नहीं है।'),
                  );
                return Column(
                  children: partners.map((partner) {
                    final d = partner.data();
                    final name =
                        (d['name'] ?? d['fullName'] ?? 'Delivery Partner')
                            .toString();
                    final phone =
                        (d['phone'] ?? d['mobile'] ?? d['mobileNumber'] ?? '')
                            .toString();
                    final total = flashMoney(
                      d['totalEarnings'] ??
                          d['earnings'] ??
                          d['lifetimeEarnings'] ??
                          0,
                    );
                    final balance = flashMoney(
                      d['walletBalance'] ?? d['unpaidEarnings'] ?? 0,
                    );
                    final count = d['deliveredOrderCount'] ?? 0;
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            Text(
                              '$phone • ${(d['branchName'] ?? d['storeName'] ?? d['branchId'] ?? 'Store not set').toString()}',
                            ),
                            const SizedBox(height: 8),
                            _payoutRow('Delivered orders', '$count'),
                            _payoutRow(
                              'Total earned (lifetime)',
                              '₹${total.toStringAsFixed(2)}',
                            ),
                            _payoutRow(
                              'Unpaid balance',
                              '₹${balance.toStringAsFixed(2)}',
                            ),
                            Align(
                              alignment: Alignment.centerRight,
                              child: FilledButton.icon(
                                onPressed: balance > 0
                                    ? () => _payDeliveryPartner(partner)
                                    : null,
                                icon: const Icon(Icons.payments_outlined),
                                label: const Text('Pay Partner'),
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
            const SizedBox(height: 20),
            const Text(
              'Delivery Partner Payment History',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
            ),
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: db
                  .collection('weeklyPayouts')
                  .where('recipientType', isEqualTo: 'deliveryPartner')
                  .snapshots(),
              builder: (context, historySnap) {
                if (historySnap.hasError)
                  return Text(
                    'Partner payment history error: ${historySnap.error}',
                  );
                if (!historySnap.hasData)
                  return const LinearProgressIndicator();
                final rows = [...historySnap.data!.docs]
                  ..sort(
                    (a, b) =>
                        flashDate(b.data()['paidAt'])?.compareTo(
                          flashDate(a.data()['paidAt']) ?? DateTime(1970),
                        ) ??
                        0,
                  );
                if (rows.isEmpty)
                  return const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      'अभी कोई delivery partner payment record नहीं है।',
                    ),
                  );
                return Column(
                  children: rows.map((doc) {
                    final d = doc.data();
                    return Card(
                      child: ListTile(
                        title: Text(
                          '${d['recipientName'] ?? 'Delivery Partner'} • ₹${flashMoney(d['amount']).toStringAsFixed(2)}',
                        ),
                        subtitle: Text(
                          '${d['branchName'] ?? d['branchId'] ?? ''} • ${d['paymentReference'] ?? ''}\n${flashDate(d['paidAt']) ?? 'Paid date unavailable'}',
                        ),
                        isThreeLine: true,
                        trailing: const Icon(
                          Icons.check_circle,
                          color: Colors.green,
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
// DELIVERY PARTNER EARNINGS - SEPARATE MENU PAGE
// ============================================================
class DeliveryPartnerEarningsPage extends StatefulWidget {
  const DeliveryPartnerEarningsPage({super.key});

  @override
  State<DeliveryPartnerEarningsPage> createState() =>
      _DeliveryPartnerEarningsPageState();
}

class _DeliveryPartnerEarningsPageState
    extends State<DeliveryPartnerEarningsPage> {
  Future<void> _payDeliveryPartner(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) async {
    final data = doc.data();
    final currentBalance = flashMoney(
      data['walletBalance'] ?? data['unpaidEarnings'] ?? 0,
    );
    if (currentBalance <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('इस Partner का कोई unpaid balance नहीं है।'),
        ),
      );
      return;
    }
    final amountController = TextEditingController(
      text: currentBalance.toStringAsFixed(2),
    );
    final referenceController = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          '${(data['name'] ?? data['fullName'] ?? 'Delivery Partner').toString()} को Payment',
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Unpaid balance: ₹${currentBalance.toStringAsFixed(2)}'),
            const SizedBox(height: 10),
            TextField(
              controller: amountController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Payment amount (₹)',
              ),
            ),
            TextField(
              controller: referenceController,
              decoration: const InputDecoration(
                labelText: 'UTR / Payment reference',
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'पहले बैंक/UPI से payment करें, फिर यहाँ confirm करें।',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Payment Confirm'),
          ),
        ],
      ),
    );
    if (ok != true) {
      amountController.dispose();
      referenceController.dispose();
      return;
    }
    final amount = flashMoney(amountController.text);
    final reference = referenceController.text.trim();
    amountController.dispose();
    referenceController.dispose();
    if (amount <= 0 || amount > currentBalance || reference.isEmpty) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('सही amount भरें और UTR/reference अनिवार्य है।'),
          ),
        );
      return;
    }
    try {
      final db = FirebaseFirestore.instance;
      final partnerRef = db.collection('deliveryPartners').doc(doc.id);
      final payoutRef = db
          .collection('weeklyPayouts')
          .doc('partner_${doc.id}_${DateTime.now().millisecondsSinceEpoch}');
      await db.runTransaction((tx) async {
        final fresh = await tx.get(partnerRef);
        if (!fresh.exists) throw StateError('Partner record नहीं मिला।');
        final freshData = fresh.data() ?? <String, dynamic>{};
        final balance = flashMoney(
          freshData['walletBalance'] ?? freshData['unpaidEarnings'] ?? 0,
        );
        if (amount > balance)
          throw StateError('Balance बदल गया है। फिर से जाँचें।');
        tx.update(partnerRef, {
          'walletBalance': balance - amount,
          'lastPayoutAt': FieldValue.serverTimestamp(),
          'lastPayoutAmount': amount,
          'updatedAt': FieldValue.serverTimestamp(),
        });
        tx.set(payoutRef, {
          'recipientType': 'deliveryPartner',
          'recipientUid': doc.id,
          'recipientName':
              (freshData['name'] ?? freshData['fullName'] ?? 'Delivery Partner')
                  .toString(),
          'phone':
              (freshData['phone'] ??
                      freshData['mobile'] ??
                      freshData['mobileNumber'] ??
                      '')
                  .toString(),
          'branchId': (freshData['branchId'] ?? '').toString(),
          'branchName':
              (freshData['branchName'] ?? freshData['storeName'] ?? '')
                  .toString(),
          'amount': amount,
          'totalEarningAtPayment': flashMoney(
            freshData['totalEarnings'] ?? freshData['earnings'] ?? 0,
          ),
          'status': 'Paid',
          'paymentReference': reference,
          'paidAt': FieldValue.serverTimestamp(),
          'paidBy': FirebaseAuth.instance.currentUser?.uid ?? '',
          'createdAt': FieldValue.serverTimestamp(),
        });
      });
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '₹${amount.toStringAsFixed(2)} payment record save हो गया।',
            ),
          ),
        );
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Payment save नहीं हुआ: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final db = FirebaseFirestore.instance;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Delivery Partner Earnings',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 5),
        const Text(
          'हर delivery partner की कुल कमाई, unpaid balance और payment करें।',
          style: TextStyle(color: grey),
        ),
        const SizedBox(height: 16),
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: db.collection('deliveryPartners').snapshots(),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Text('Partner earnings load error: ${snapshot.error}');
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final partners = [...snapshot.data!.docs]
              ..sort(
                (a, b) => (a.data()['name'] ?? a.data()['fullName'] ?? '')
                    .toString()
                    .compareTo(
                      (b.data()['name'] ?? b.data()['fullName'] ?? '')
                          .toString(),
                    ),
              );
            if (partners.isEmpty) {
              return const Padding(
                padding: EdgeInsets.all(12),
                child: Text('अभी कोई delivery partner नहीं है।'),
              );
            }
            return Column(
              children: partners.map((partner) {
                final d = partner.data();
                final name = (d['name'] ?? d['fullName'] ?? 'Delivery Partner')
                    .toString();
                final phone =
                    (d['phone'] ?? d['mobile'] ?? d['mobileNumber'] ?? '')
                        .toString();
                final total = flashMoney(
                  d['totalEarnings'] ??
                      d['earnings'] ??
                      d['lifetimeEarnings'] ??
                      0,
                );
                final balance = flashMoney(
                  d['walletBalance'] ?? d['unpaidEarnings'] ?? 0,
                );
                final count = d['deliveredOrderCount'] ?? 0;
                return Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '$phone • ${(d['branchName'] ?? d['storeName'] ?? d['branchId'] ?? 'Store not set').toString()}',
                        ),
                        const Divider(height: 22),
                        _payoutRow('Delivered orders', '$count'),
                        _payoutRow(
                          'Total earned (lifetime)',
                          '₹${total.toStringAsFixed(2)}',
                        ),
                        _payoutRow(
                          'Unpaid balance',
                          '₹${balance.toStringAsFixed(2)}',
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerRight,
                          child: FilledButton.icon(
                            onPressed: balance > 0
                                ? () => _payDeliveryPartner(partner)
                                : null,
                            icon: const Icon(Icons.payments_outlined),
                            label: const Text('Pay Partner'),
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
        const SizedBox(height: 20),
        const Text(
          'Delivery Partner Payment History',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 8),
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: db
              .collection('weeklyPayouts')
              .where('recipientType', isEqualTo: 'deliveryPartner')
              .snapshots(),
          builder: (context, historySnap) {
            if (historySnap.hasError) {
              return Text(
                'Partner payment history error: ${historySnap.error}',
              );
            }
            if (!historySnap.hasData) {
              return const LinearProgressIndicator();
            }
            final rows = [...historySnap.data!.docs]
              ..sort(
                (a, b) => (flashDate(b.data()['paidAt']) ?? DateTime(1970))
                    .compareTo(flashDate(a.data()['paidAt']) ?? DateTime(1970)),
              );
            if (rows.isEmpty) {
              return const Padding(
                padding: EdgeInsets.all(12),
                child: Text('अभी कोई delivery partner payment record नहीं है।'),
              );
            }
            return Column(
              children: rows.map((doc) {
                final d = doc.data();
                return Card(
                  child: ListTile(
                    title: Text(
                      '${d['recipientName'] ?? 'Delivery Partner'} • ₹${flashMoney(d['amount']).toStringAsFixed(2)}',
                    ),
                    subtitle: Text(
                      '${d['branchName'] ?? d['branchId'] ?? ''} • ${d['paymentReference'] ?? ''}\\n${flashDate(d['paidAt']) ?? 'Paid date unavailable'}',
                    ),
                    isThreeLine: true,
                    trailing: const Icon(
                      Icons.check_circle,
                      color: Colors.green,
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
