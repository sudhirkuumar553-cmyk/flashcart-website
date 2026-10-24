import 'dart:async';

import 'package:geocoding/geocoding.dart';
import 'package:flutter/material.dart';

import 'package:firebase_core/firebase_core.dart';

import 'package:firebase_auth/firebase_auth.dart';

import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:flutter/services.dart';

import 'dart:convert';

import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';

import 'firebase_options.dart';

const flashCartSupportEmail = 'sudhirkuumar553@gmail.com';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await CustomerNotificationService.initialize();
  runApp(const FlashCartApp());
}

// ======================================================
// NOTIFICATIONS / HOURLY ORDER REMINDER
// ======================================================
class CustomerNotificationService {
  static final FlutterLocalNotificationsPlugin plugin =
      FlutterLocalNotificationsPlugin();
  static StreamSubscription? _announcementSub;

  static Future<void> initialize() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: android);
    await plugin.initialize(settings: settings);
    await plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
    const channel = AndroidNotificationChannel(
      'flashcart_customer',
      'FlashCart Notifications',
      description: 'FlashCart offers, announcements and order reminders',
      importance: Importance.high,
    );
    await plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(channel);
    await plugin.periodicallyShow(
      id: 9101,
      title: '🛒 FlashCart Reminder',
      body: 'Fresh groceries available — order now!',
      repeatInterval: RepeatInterval.hourly,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'flashcart_customer',
          'FlashCart Notifications',
          channelDescription:
              'FlashCart offers, announcements and order reminders',
          importance: Importance.high,
          priority: Priority.high,
          playSound: true,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    );

    _announcementSub?.cancel();
    _announcementSub = FirebaseFirestore.instance
        .collection('adminNotifications')
        .where('published', isEqualTo: true)
        .snapshots()
        .listen((snapshot) async {
          for (final change in snapshot.docChanges) {
            if (change.type != DocumentChangeType.added) continue;
            final data = change.doc.data();
            if (data == null) continue;
            final audience = (data['audience'] ?? 'all').toString();
            if (audience != 'all' && audience != 'customers') continue;
            await plugin.show(
              id: change.doc.id.hashCode & 0x7fffffff,
              title: data['title']?.toString() ?? 'FlashCart',
              body: data['message']?.toString() ?? '',
              notificationDetails: const NotificationDetails(
                android: AndroidNotificationDetails(
                  'flashcart_customer',
                  'FlashCart Notifications',
                  channelDescription: 'FlashCart announcements',
                  importance: Importance.high,
                  priority: Priority.high,
                  playSound: true,
                ),
              ),
            );
          }
        });
  }

  static Future<void> dispose() async {
    await _announcementSub?.cancel();
    _announcementSub = null;
  }
}

// ======================================================

// APP

// ======================================================

class FlashCartApp extends StatelessWidget {
  const FlashCartApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,

      title: 'FlashCart',

      theme: ThemeData(
        useMaterial3: true,

        fontFamily: 'Arial',

        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFE53935)),
      ),

      home: const AuthGate(),
    );
  }
}

// ======================================================

// AUTH GATE

// ======================================================

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),

      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SplashPage();
        }

        if (snapshot.hasData) {
          return const HomePage();
        }
        return const PhoneAuthPage();
      },
    );
  }
}

// ======================================================

// SPLASH

// ======================================================

class SplashPage extends StatelessWidget {
  const SplashPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFE53935),

      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,

          children: [
            Container(
              width: 100,

              height: 100,

              decoration: BoxDecoration(
                color: Colors.white,

                borderRadius: BorderRadius.circular(28),
              ),

              child: const Icon(
                Icons.shopping_bag_rounded,

                size: 60,

                color: Color(0xFFE53935),
              ),
            ),

            const SizedBox(height: 25),

            const Text(
              'FlashCart',

              style: TextStyle(
                color: Colors.white,

                fontSize: 32,

                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 8),

            const Text(
              'Fresh groceries, fast delivery',

              style: TextStyle(color: Colors.white70, fontSize: 15),
            ),

            const SizedBox(height: 30),

            const CircularProgressIndicator(color: Colors.white),
          ],
        ),
      ),
    );
  }
}

class CustomerNotificationsPage extends StatelessWidget {
  const CustomerNotificationsPage({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Notifications',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('adminNotifications')
            .where('published', isEqualTo: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError)
            return Center(
              child: Text('Notifications load नहीं हुए: ${snapshot.error}'),
            );
          if (!snapshot.hasData)
            return const Center(child: CircularProgressIndicator());
          final docs =
              snapshot.data!.docs.where((d) {
                final audience = (d.data()['audience'] ?? 'all').toString();
                return audience == 'all' || audience == 'customers';
              }).toList()..sort((a, b) {
                final at = a.data()['createdAt'];
                final bt = b.data()['createdAt'];
                if (at is Timestamp && bt is Timestamp) return bt.compareTo(at);
                return 0;
              });
          if (docs.isEmpty)
            return const Center(child: Text('अभी कोई notification नहीं है'));
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: docs.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (_, i) {
              final x = docs[i].data();
              return Card(
                child: ListTile(
                  leading: const CircleAvatar(
                    child: Icon(Icons.notifications_active_rounded),
                  ),
                  title: Text(x['title']?.toString() ?? 'FlashCart'),
                  subtitle: Text(x['message']?.toString() ?? ''),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// ======================================================
// PRODUCT MODEL

// ======================================================

class Product {
  final String id;

  final String name;

  final String category;

  final String unit;

  final double price;

  final double originalPrice;

  final double discount;

  final int stock;

  final bool available;
  final String imageUrl;

  final String description;

  final String emoji;
  final int deliveryMinutes;
  final double ratingAverage;
  final int ratingCount;

  Product({
    this.id = '',
    required this.name,

    required this.category,

    required this.unit,

    required this.price,

    this.originalPrice = 0,

    this.discount = 0,

    this.stock = 0,

    this.available = true,

    this.imageUrl = '',

    this.description = '',

    this.emoji = '   🛍️',
    this.deliveryMinutes = 10,
    this.ratingAverage = 0,
    this.ratingCount = 0,
  });
  factory Product.fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? {};

    final original =
        (data['originalPrice'] as num?)?.toDouble() ??
        (data['price'] as num?)?.toDouble() ??
        0;

    final discount =
        (data['discountPercent'] as num?)?.toDouble() ??
        (data['discount'] as num?)?.toDouble() ??
        0;

    final storedSelling = (data['sellingPrice'] as num?)?.toDouble();

    final calculatedSelling = discount > 0
        ? original - (original * discount / 100)
        : original;

    return Product(
      id: doc.id,

      name: data['name']?.toString() ?? 'Unnamed Product',

      category: data['category']?.toString() ?? 'Other',

      unit: data['unit']?.toString() ?? '1 unit',

      price: storedSelling ?? calculatedSelling,

      originalPrice: original,

      discount: discount,

      stock: (data['stock'] as num?)?.toInt() ?? 0,

      available: data['available'] is bool ? data['available'] as bool : true,

      imageUrl: data['imageUrl']?.toString() ?? '',

      description:
          (data['description'] ??
                  data['productDescription'] ??
                  data['details'] ??
                  '')
              .toString(),

      emoji: data['emoji']?.toString() ?? '  🛍️',
      deliveryMinutes: (data['deliveryMinutes'] as num?)?.toInt() ?? 10,
      ratingAverage: (data['ratingAverage'] as num?)?.toDouble() ?? 0,
      ratingCount: (data['ratingCount'] as num?)?.toInt() ?? 0,
    );
  }
}

// ======================================================

// CART MODEL

// ======================================================

// ======================================================
// PRODUCT RATINGS, REVIEWS, QUANTITY CONTROLS AND POSTER SLIDER
// ======================================================

class _ProductQuantityControl extends StatelessWidget {
  final int quantity;
  final bool enabled;
  final VoidCallback onAdd;
  final VoidCallback onIncrease;
  final VoidCallback onDecrease;

  const _ProductQuantityControl({
    required this.quantity,
    required this.enabled,
    required this.onAdd,
    required this.onIncrease,
    required this.onDecrease,
  });

  @override
  Widget build(BuildContext context) {
    if (quantity <= 0) {
      return SizedBox(
        height: 36,
        child: OutlinedButton(
          onPressed: enabled ? onAdd : null,
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF188A42),
            side: const BorderSide(color: Color(0xFF188A42), width: 1.5),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: const Text(
            'ADD',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900),
          ),
        ),
      );
    }
    return Container(
      height: 32,
      decoration: BoxDecoration(
        color: const Color(0xFF188A42),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 23, height: 32),
            onPressed: onDecrease,
            icon: const Icon(Icons.remove, size: 15, color: Colors.white),
          ),
          Text(
            '$quantity',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w900,
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 23, height: 32),
            onPressed: enabled ? onIncrease : null,
            icon: const Icon(Icons.add, size: 15, color: Colors.white),
          ),
        ],
      ),
    );
  }
}

class _ProductRatingLine extends StatelessWidget {
  final String productId;
  final double fallbackAverage;
  final int fallbackCount;

  const _ProductRatingLine({
    required this.productId,
    required this.fallbackAverage,
    required this.fallbackCount,
  });

  @override
  Widget build(BuildContext context) {
    if (productId.isEmpty) return _line(fallbackAverage, fallbackCount);
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('productReviews')
          .where('productId', isEqualTo: productId)
          .snapshots(),
      builder: (context, snapshot) {
        var average = fallbackAverage;
        var count = fallbackCount;
        if (snapshot.hasData && snapshot.data!.docs.isNotEmpty) {
          final docs = snapshot.data!.docs;
          final total = docs.fold<int>(
            0,
            (sum, doc) => sum + ((doc.data()['stars'] as num?)?.toInt() ?? 0),
          );
          count = docs.length;
          average = total / count;
        }
        return _line(average, count);
      },
    );
  }

  Widget _line(double average, int count) {
    return Row(
      children: [
        const Icon(Icons.star_rounded, color: Color(0xFFFFB800), size: 15),
        const SizedBox(width: 2),
        Text(
          count > 0 ? '${average.toStringAsFixed(1)} ($count)' : 'New',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 10.5,
            color: Color(0xFF5D5D5D),
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _ProductReviewsSection extends StatelessWidget {
  final String productId;
  final String productName;
  const _ProductReviewsSection({
    required this.productId,
    required this.productName,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('productReviews')
          .where('productId', isEqualTo: productId)
          .snapshots(),
      builder: (context, snapshot) {
        final docs = snapshot.data?.docs.toList() ?? [];
        docs.sort((a, b) {
          final aa = a.data()['createdAt'];
          final bb = b.data()['createdAt'];
          if (aa is Timestamp && bb is Timestamp) return bb.compareTo(aa);
          return 0;
        });
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Ratings & Reviews',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => _writeReview(context),
                  icon: const Icon(Icons.rate_review_outlined, size: 18),
                  label: const Text('Rate'),
                ),
              ],
            ),
            if (snapshot.hasError)
              const Text(
                'Reviews अभी load नहीं हो पाए।',
                style: TextStyle(color: Colors.grey),
              )
            else if (!snapshot.hasData)
              const Padding(
                padding: EdgeInsets.all(8),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else if (docs.isEmpty)
              const Text(
                'अभी कोई review नहीं है। पहला review आप दें।',
                style: TextStyle(color: Colors.grey),
              )
            else
              ...docs.take(5).map((doc) {
                final data = doc.data();
                final stars = (data['stars'] as num?)?.toInt() ?? 0;
                final review = data['review']?.toString() ?? '';
                final name = data['customerName']?.toString() ?? 'Customer';
                return Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(top: 7),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF7F7F7),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              name,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          Text(
                            '★' * stars,
                            style: const TextStyle(color: Color(0xFFFFB800)),
                          ),
                        ],
                      ),
                      if (review.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(review),
                        ),
                    ],
                  ),
                );
              }),
          ],
        );
      },
    );
  }

  Future<void> _writeReview(BuildContext context) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Review देने के लिए पहले login करें।')),
      );
      return;
    }

    // A customer may rate a product only after an order containing it is delivered.
    String? eligibleOrderId;
    try {
      final orders = await FirebaseFirestore.instance
          .collection('orders')
          .where('userId', isEqualTo: user.uid)
          .get();
      for (final orderDoc in orders.docs) {
        final data = orderDoc.data();
        if ((data['status'] ?? '').toString().trim().toLowerCase() !=
            'delivered')
          continue;
        final rawItems = data['items'];
        if (rawItems is! List) continue;
        final containsProduct = rawItems.any((raw) {
          if (raw is! Map) return false;
          final itemId = (raw['productId'] ?? raw['id'] ?? '').toString();
          final itemName = (raw['name'] ?? '').toString().trim().toLowerCase();
          return (itemId.isNotEmpty && itemId == productId) ||
              (itemName.isNotEmpty &&
                  itemName == productName.trim().toLowerCase());
        });
        if (containsProduct) {
          eligibleOrderId = orderDoc.id;
          break;
        }
      }
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Order verify नहीं हो पाया। कृपया फिर कोशिश करें।'),
        ),
      );
      return;
    }
    if (eligibleOrderId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Rating केवल यह product खरीदकर order Delivered होने के बाद दे सकते हैं।',
          ),
        ),
      );
      return;
    }

    final controller = TextEditingController();
    int stars = 5;
    bool saving = false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setLocal) => AlertDialog(
          title: const Text('Rate this product'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Wrap(
                alignment: WrapAlignment.center,
                children: List.generate(
                  5,
                  (i) => IconButton(
                    onPressed: saving
                        ? null
                        : () => setLocal(() => stars = i + 1),
                    icon: Icon(
                      i < stars
                          ? Icons.star_rounded
                          : Icons.star_outline_rounded,
                      color: const Color(0xFFFFB800),
                      size: 30,
                    ),
                  ),
                ),
              ),
              TextField(
                controller: controller,
                maxLines: 3,
                maxLength: 300,
                decoration: const InputDecoration(
                  hintText: 'Write your review (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
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
                      setLocal(() => saving = true);
                      try {
                        final userDoc = await FirebaseFirestore.instance
                            .collection('users')
                            .doc(user.uid)
                            .get();
                        final userData = userDoc.data() ?? <String, dynamic>{};
                        final verifiedOrder = await FirebaseFirestore.instance
                            .collection('orders')
                            .doc(eligibleOrderId)
                            .get();
                        final verifiedData =
                            verifiedOrder.data() ?? <String, dynamic>{};
                        if (!verifiedOrder.exists ||
                            verifiedData['userId']?.toString() != user.uid ||
                            verifiedData['status']?.toString().toLowerCase() !=
                                'delivered') {
                          throw StateError(
                            'Order Delivered नहीं है; rating नहीं दी जा सकती।',
                          );
                        }
                        await FirebaseFirestore.instance
                            .collection('productReviews')
                            .doc('${productId}_${user.uid}')
                            .set({
                              'productId': productId,
                              'orderId': eligibleOrderId,
                              'customerUid': user.uid,
                              'customerName':
                                  (userData['profileName'] ??
                                          userData['name'] ??
                                          'Customer')
                                      .toString(),
                              'stars': stars,
                              'review': controller.text.trim(),
                              'createdAt': FieldValue.serverTimestamp(),
                            }, SetOptions(merge: true));
                        if (dialogContext.mounted) Navigator.pop(dialogContext);
                        if (context.mounted)
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Review submit हो गया।'),
                            ),
                          );
                      } catch (e) {
                        setLocal(() => saving = false);
                        if (dialogContext.mounted)
                          ScaffoldMessenger.of(dialogContext).showSnackBar(
                            SnackBar(
                              content: Text('Review submit नहीं हुआ: $e'),
                            ),
                          );
                      }
                    },
              child: saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Submit'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
  }
}

class _HomePosterCarousel extends StatefulWidget {
  final List<Map<String, dynamic>> posters;
  const _HomePosterCarousel({required this.posters});

  @override
  State<_HomePosterCarousel> createState() => _HomePosterCarouselState();
}

class _HomePosterCarouselState extends State<_HomePosterCarousel> {
  final PageController _controller = PageController(viewportFraction: 0.92);
  Timer? _timer;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  @override
  void didUpdateWidget(covariant _HomePosterCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.posters.length != widget.posters.length) {
      _index = 0;
      if (_controller.hasClients) _controller.jumpToPage(0);
      _startTimer();
    }
  }

  void _startTimer() {
    _timer?.cancel();
    if (widget.posters.length < 2) return;
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || !_controller.hasClients) return;
      _controller.animateToPage(
        (_index + 1) % widget.posters.length,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeInOut,
      );
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 158,
      child: PageView.builder(
        controller: _controller,
        itemCount: widget.posters.length,
        onPageChanged: (index) => setState(() => _index = index),
        itemBuilder: (context, index) {
          final data = widget.posters[index];
          final imageUrl = (data['imageUrl'] ?? data['image'] ?? '').toString();
          final title = (data['title'] ?? 'FlashCart Offers').toString();
          final subtitle = (data['subtitle'] ?? data['description'] ?? '')
              .toString();
          return Padding(
            padding: const EdgeInsets.fromLTRB(5, 8, 5, 2),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Color(0xFF8D4A00), Color(0xFFFFA800)],
                      ),
                    ),
                  ),
                  if (imageUrl.isNotEmpty)
                    Image.network(
                      imageUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  if (title.isNotEmpty || subtitle.isNotEmpty)
                    Align(
                      alignment: Alignment.bottomLeft,
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.fromLTRB(14, 22, 14, 10),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              Colors.black.withOpacity(0.68),
                            ],
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w900,
                                fontSize: 17,
                              ),
                            ),
                            if (subtitle.isNotEmpty)
                              Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  Positioned(
                    right: 12,
                    top: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.92),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        '${index + 1}/${widget.posters.length}',
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class CartItem {
  Product product;

  int quantity;

  CartItem({required this.product, this.quantity = 1});

  double get total => product.price * quantity;
}

// ======================================================

// HOME PAGE
// ======================================================

class _FlashCartHeaderDelegate extends SliverPersistentHeaderDelegate {
  final Widget child;
  final double height;

  _FlashCartHeaderDelegate({required this.child, required this.height});

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Material(
      color: Colors.white,
      elevation: overlapsContent ? 3 : 0,
      child: SizedBox(height: height, child: child),
    );
  }

  @override
  bool shouldRebuild(covariant _FlashCartHeaderDelegate oldDelegate) {
    return oldDelegate.child != child || oldDelegate.height != height;
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int selectedTab = 0;
  String selectedCategory = 'All';
  bool showDiscountedOnly = false;

  String searchText = '';

  final TextEditingController searchController = TextEditingController();

  late final Stream<QuerySnapshot<Map<String, dynamic>>> productsStream;

  final List<CartItem> cart = [];

  final Set<String> favorites = <String>{};

  String profileName = '';
  String profileImageBase64 = '';
  bool profileLoading = false;

  User? get currentUser => FirebaseAuth.instance.currentUser;

  @override
  void initState() {
    super.initState();
    productsStream = FirebaseFirestore.instance
        .collection('products')
        .snapshots();
    _loadCustomerProfile();
  }

  Future<void> _loadCustomerProfile() async {
    final uid = currentUser?.uid;
    if (uid == null) return;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      final data = snap.data() ?? <String, dynamic>{};
      if (!mounted) return;
      setState(() {
        profileName =
            data['profileName']?.toString() ?? data['name']?.toString() ?? '';
        profileImageBase64 = data['profileImageBase64']?.toString() ?? '';
      });
    } catch (_) {
      // Profile is optional; never block the home screen.
    }
  }

  Future<void> _editCustomerProfile() async {
    final uid = currentUser?.uid;
    if (uid == null) return;
    final nameController = TextEditingController(text: profileName);
    String imageBase64 = profileImageBase64;
    bool saving = false;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setLocal) {
            Future<void> pickImage() async {
              try {
                final file = await ImagePicker().pickImage(
                  source: ImageSource.gallery,
                  imageQuality: 60,
                  maxWidth: 900,
                  maxHeight: 900,
                );
                if (file == null) return;
                final bytes = await file.readAsBytes();
                if (bytes.length > 450000) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Profile photo 450 KB से छोटी रखें'),
                      ),
                    );
                  }
                  return;
                }
                setLocal(() => imageBase64 = base64Encode(bytes));
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Photo select नहीं हो सका: $e')),
                  );
                }
              }
            }

            Future<void> save() async {
              final name = nameController.text.trim();
              if (name.length < 2) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('कम से कम 2 अक्षर का नाम डालें'),
                  ),
                );
                return;
              }
              setLocal(() => saving = true);
              try {
                await FirebaseFirestore.instance
                    .collection('users')
                    .doc(uid)
                    .set({
                      'profileName': name,
                      'profileImageBase64': imageBase64,
                      'updatedAt': FieldValue.serverTimestamp(),
                    }, SetOptions(merge: true));
                if (!mounted) return;
                setState(() {
                  profileName = name;
                  profileImageBase64 = imageBase64;
                });
                if (dialogContext.mounted) Navigator.pop(dialogContext);
                _showSnack('Profile updated ✓');
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Profile save नहीं हुआ: $e')),
                  );
                }
                setLocal(() => saving = false);
              }
            }

            return AlertDialog(
              title: const Text(
                'Edit Profile',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircleAvatar(
                      radius: 42,
                      backgroundColor: const Color(0xFFFFEBEE),
                      backgroundImage: imageBase64.isNotEmpty
                          ? MemoryImage(base64Decode(imageBase64))
                          : null,
                      child: imageBase64.isEmpty
                          ? const Icon(
                              Icons.person_rounded,
                              size: 44,
                              color: Color(0xFFE53935),
                            )
                          : null,
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: saving ? null : pickImage,
                      icon: const Icon(Icons.photo_camera_back_rounded),
                      label: const Text('Change Photo'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: nameController,
                      enabled: !saving,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Full Name',
                        prefixIcon: Icon(Icons.person_outline_rounded),
                        border: OutlineInputBorder(),
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
                  onPressed: saving ? null : save,
                  child: saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
    nameController.dispose();
  }

  List<Product> _productsFromSnapshot(
    QuerySnapshot<Map<String, dynamic>> snapshot,
  ) {
    final list = snapshot.docs.map(Product.fromFirestore).toList();

    list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return list;
  }

  List<Product> _filterProducts(List<Product> products) {
    return products.where((product) {
      final categoryMatch =
          selectedCategory == 'All' ||
          product.category.toLowerCase() == selectedCategory.toLowerCase();

      final searchMatch =
          product.name.toLowerCase().contains(
            searchText.trim().toLowerCase(),
          ) ||
          product.category.toLowerCase().contains(
            searchText.trim().toLowerCase(),
          );
      return categoryMatch && searchMatch;
    }).toList();
  }

  int quantityInCart(Product product) {
    final index = cart.indexWhere((item) => item.product.id == product.id);
    return index < 0 ? 0 : cart[index].quantity;
  }

  int get totalItems => cart.fold(0, (sum, item) => sum + item.quantity);

  double get cartTotal => cart.fold(0, (sum, item) => sum + item.total);

  void addToCart(Product product) {
    if (!product.available || product.stock <= 0) {
      _showSnack('This product is currently unavailable', error: true);

      return;
    }

    setState(() {
      final index = cart.indexWhere((item) => item.product.id == product.id);

      if (index >= 0) {
        if (cart[index].quantity < product.stock) {
          cart[index].quantity++;
        }
      } else {
        cart.add(CartItem(product: product));
      }
    });

    _showSnack('${product.name} added to cart ✓');
  }

  void increaseQuantity(int index) {
    final item = cart[index];
    if (item.quantity >= item.product.stock) {
      _showSnack('Only ${item.product.stock} available in stock');

      return;
    }

    setState(() => item.quantity++);
  }

  void decreaseQuantity(int index) {
    setState(() {
      if (cart[index].quantity > 1) {
        cart[index].quantity--;
      } else {
        cart.removeAt(index);
      }
    });
  }

  void toggleFavorite(Product product) {
    setState(() {
      if (favorites.contains(product.id)) {
        favorites.remove(product.id);
      } else {
        favorites.add(product.id);
      }
    });
  }

  void openOrders() {
    Navigator.push(
      context,

      MaterialPageRoute(builder: (_) => const MyOrdersPage()),
    );
  }

  Future<void> logout() async {
    await FirebaseAuth.instance.signOut();
  }

  void _showSnack(String message, {bool error = false}) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),

          behavior: SnackBarBehavior.floating,

          backgroundColor: error
              ? Colors.red.shade700
              : const Color(0xFF2D2523),

          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),

          duration: const Duration(milliseconds: 1400),
        ),
      );
  }

  @override
  void dispose() {
    searchController.dispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),

      body: SafeArea(
        child: selectedTab == 0
            ? buildHome()
            : selectedTab == 2
            ? buildCategoriesPage()
            : selectedTab == 3
            ? buildCart()
            : buildProfile(),
      ),
      bottomNavigationBar: NavigationBar(
        backgroundColor: Colors.white,
        elevation: 10,
        indicatorColor: const Color(0xFFFFE7D6),
        selectedIndex: selectedTab,
        onDestinationSelected: (index) {
          if (index == 1) {
            openOrders();
            return;
          }
          setState(() => selectedTab = index);
        },
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded, color: Color(0xFFE53935)),
            label: 'Home',
          ),
          const NavigationDestination(
            icon: Icon(Icons.receipt_long_outlined),
            selectedIcon: Icon(Icons.receipt_long_rounded),
            label: 'Orders',
          ),
          const NavigationDestination(
            icon: Icon(Icons.grid_view_rounded),
            selectedIcon: Icon(
              Icons.grid_view_rounded,
              color: Color(0xFFE53935),
            ),
            label: 'Categories',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: totalItems > 0,
              label: Text('$totalItems'),
              child: const Icon(Icons.shopping_bag_outlined),
            ),
            selectedIcon: Badge(
              isLabelVisible: totalItems > 0,
              label: Text('$totalItems'),
              child: const Icon(
                Icons.shopping_bag_rounded,
                color: Color(0xFFE53935),
              ),
            ),
            label: 'Cart',
          ),
          const NavigationDestination(
            icon: Icon(Icons.person_outline_rounded),
            selectedIcon: Icon(Icons.person_rounded, color: Color(0xFFE53935)),
            label: 'Profile',
          ),
        ],
      ),
    );
  }

  Widget buildCategoriesPage() {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: productsStream,
      builder: (context, snapshot) {
        if (snapshot.hasError)
          return _errorState('Categories unavailable', '${snapshot.error}');
        if (!snapshot.hasData)
          return const Center(child: CircularProgressIndicator());
        final products = _productsFromSnapshot(snapshot.data!)
            .where((p) => p.available && p.stock > 0)
            .toList();
        final categories = <String>{
          'All',
          ...products.map((p) => p.category),
        }.toList();
        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Container(
                padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFFFFB52E), Color(0xFFFF8A24)],
                  ),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Shop by category',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 25,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    SizedBox(height: 5),
                    Text(
                      'Find everyday essentials in one place',
                      style: TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  mainAxisExtent: 112,
                ),
                delegate: SliverChildBuilderDelegate((context, index) {
                  final category = categories[index];
                  final count = category == 'All'
                      ? products.length
                      : products
                            .where(
                              (p) =>
                                  p.category.toLowerCase() ==
                                  category.toLowerCase(),
                            )
                            .length;
                  return Material(
                    color: index.isEven
                        ? const Color(0xFFFFF1E6)
                        : const Color(0xFFEAF6EC),
                    borderRadius: BorderRadius.circular(18),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(18),
                      onTap: () {
                        setState(() {
                          selectedCategory = category;
                          showDiscountedOnly = false;
                          selectedTab = 0;
                        });
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          children: [
                            Text(
                              category == 'All'
                                  ? '🛍️'
                                  : _categoryEmoji(category),
                              style: const TextStyle(fontSize: 30),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    category,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w900,
                                      fontSize: 14,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '$count products',
                                    style: const TextStyle(
                                      color: Colors.black54,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }, childCount: categories.length),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget buildHome() {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: productsStream,

      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _errorState('Unable to load products', '${snapshot.error}');
        }
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _loadingHome();
        }

        final allProducts = _productsFromSnapshot(snapshot.data!);

        final availableProducts = allProducts
            .where((p) => p.available && p.stock > 0)
            .toList();
        final filteredProducts = _filterProducts(availableProducts)
            .where(
              (p) =>
                  !showDiscountedOnly ||
                  p.discount > 0 ||
                  p.originalPrice > p.price,
            )
            .toList();

        final categories = <String>{
          'All',

          ...availableProducts.map((p) => p.category),
        }.toList();

        if (selectedCategory != 'All' &&
            !categories.contains(selectedCategory)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => selectedCategory = 'All');
          });
        }

        return CustomScrollView(
          physics: const BouncingScrollPhysics(),

          slivers: [
            SliverPersistentHeader(
              pinned: true,
              delegate: _FlashCartHeaderDelegate(
                child: buildHeader(),
                height: 78,
              ),
            ),

            SliverToBoxAdapter(child: buildSearch()),

            SliverToBoxAdapter(child: buildBanner()),
            SliverToBoxAdapter(child: buildOfferStrip()),
            SliverToBoxAdapter(child: buildCategories(categories)),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 22, 16, 12),

                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Shop your essentials',

                        style: TextStyle(
                          fontSize: 22,

                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    Text(
                      '${filteredProducts.length} items',

                      style: const TextStyle(
                        color: Colors.grey,

                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            if (filteredProducts.isEmpty)
              SliverToBoxAdapter(child: _emptyProducts())
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                sliver: SliverGrid(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) =>
                        buildProductCard(filteredProducts[index]),

                    childCount: filteredProducts.length,
                  ),

                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    // Compact product cards: avoid large empty areas below ADD.
                    mainAxisExtent: 360,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _loadingHome() {
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: buildHeader()),

        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(40),

            child: Center(child: CircularProgressIndicator()),
          ),
        ),
      ],
    );
  }

  Widget _errorState(String title, String subtitle) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(30),

        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,

          children: [
            const Icon(Icons.cloud_off_rounded, size: 70, color: Colors.grey),

            const SizedBox(height: 14),

            Text(
              title,

              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),

            Text(
              subtitle,

              textAlign: TextAlign.center,

              style: const TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyProducts() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 45, 30, 60),

      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(22),
            decoration: const BoxDecoration(
              color: Colors.white,

              shape: BoxShape.circle,
            ),

            child: const Icon(
              Icons.search_off_rounded,

              size: 55,

              color: Colors.grey,
            ),
          ),
          const SizedBox(height: 16),

          const Text(
            'No products found',

            style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),

          const Text(
            'Try another category or search term.',

            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFFB52E), Color(0xFFFF8A24)],
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(15),
            ),
            child: const Icon(
              Icons.shopping_bag_rounded,
              color: Color(0xFFE53935),
              size: 26,
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                RichText(
                  text: const TextSpan(
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.5,
                    ),
                    children: [
                      TextSpan(
                        text: 'Flash',
                        style: TextStyle(color: Colors.white),
                      ),
                      TextSpan(
                        text: 'Cart',
                        style: TextStyle(color: Color(0xFF185B2C)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 2),
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () {
                    if (cart.isEmpty) {
                      setState(() => selectedTab = 3);
                      _showSnack(
                        'Cart में product जोड़ें; checkout पर delivery address चुनें।',
                      );
                    } else {
                      setState(() => selectedTab = 3);
                      _showSnack(
                        'Checkout खोलकर delivery address चुनें या बदलें।',
                      );
                    }
                  },
                  child: const Row(
                    children: [
                      Icon(
                        Icons.location_on_rounded,
                        color: Colors.white,
                        size: 14,
                      ),
                      SizedBox(width: 3),
                      Expanded(
                        child: Text(
                          'Delivery address • Tap to select',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Icon(
                        Icons.keyboard_arrow_down_rounded,
                        color: Colors.white,
                        size: 15,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'My Orders',
            onPressed: openOrders,
            style: IconButton.styleFrom(
              backgroundColor: Colors.white.withOpacity(0.20),
            ),
            icon: const Icon(
              Icons.receipt_long_rounded,
              color: Colors.white,
              size: 26,
            ),
          ),
          IconButton(
            tooltip: 'Profile',
            onPressed: () => setState(() => selectedTab = 4),
            style: IconButton.styleFrom(
              backgroundColor: Colors.white.withOpacity(0.20),
            ),
            icon: const Icon(
              Icons.person_rounded,
              color: Colors.white,
              size: 26,
            ),
          ),
        ],
      ),
    );
  }

  Widget buildSearch() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),

      child: TextField(
        controller: searchController,

        textInputAction: TextInputAction.search,

        onChanged: (value) => setState(() => searchText = value),

        decoration: InputDecoration(
          hintText: 'Search for atta, dal, fruits, snacks...',

          prefixIcon: const Icon(Icons.search_rounded, size: 28),

          suffixIcon: searchText.isNotEmpty
              ? IconButton(
                  onPressed: () {
                    searchController.clear();

                    setState(() => searchText = '');

                    FocusScope.of(context).requestFocus();
                  },

                  icon: const Icon(Icons.close_rounded),
                )
              : const Icon(Icons.tune_rounded),

          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(vertical: 18),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(19),
            borderSide: const BorderSide(color: Color(0xFFE7E7E7)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(19),
            borderSide: const BorderSide(color: Color(0xFFE53935), width: 1.5),
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(19),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  Widget buildBanner() {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      // Admin App saves festival/offer posters in `homeBanners` with `enabled`,
      // `startAt`, `endAt`, `imageUrl`, `title`, and `subtitle` fields.
      // Keep this stream aligned with that schema so Admin uploads appear here.
      stream: FirebaseFirestore.instance
          .collection('homeBanners')
          .where('enabled', isEqualTo: true)
          .snapshots(),
      builder: (context, snapshot) {
        final now = DateTime.now();
        final posters =
            (snapshot.data?.docs ?? []).where((doc) {
              final data = doc.data();
              final startAt = data['startAt'];
              final endAt = data['endAt'];
              final autoSchedule = data['autoSchedule'] == true;
              final notStarted =
                  autoSchedule &&
                  startAt is Timestamp &&
                  startAt.toDate().isAfter(now);
              final expired =
                  autoSchedule &&
                  endAt is Timestamp &&
                  !endAt.toDate().isAfter(now);
              return !notStarted && !expired;
            }).toList()..sort((a, b) {
              final aOrder = (a.data()['sortOrder'] as num?)?.toInt();
              final bOrder = (b.data()['sortOrder'] as num?)?.toInt();
              if (aOrder != null || bOrder != null) {
                return (aOrder ?? 999).compareTo(bOrder ?? 999);
              }
              final aCreated = a.data()['createdAt'];
              final bCreated = b.data()['createdAt'];
              final aTime = aCreated is Timestamp
                  ? aCreated.millisecondsSinceEpoch
                  : 0;
              final bTime = bCreated is Timestamp
                  ? bCreated.millisecondsSinceEpoch
                  : 0;
              return bTime.compareTo(aTime);
            });

        if (posters.isEmpty) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Container(
              padding: const EdgeInsets.fromLTRB(18, 16, 14, 16),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF8D4A00), Color(0xFFFFA800)],
                ),
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: Colors.orange.withOpacity(0.18),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: const Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'WELCOME TO FLASHCART ⚡',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            height: 1.05,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        SizedBox(height: 7),
                        Text(
                          'Your daily essentials, all in one place',
                          style: TextStyle(color: Colors.white, fontSize: 14),
                        ),
                        SizedBox(height: 13),
                        Text(
                          'SHOP SMART • SHOP FRESH',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Text('🛍️', style: TextStyle(fontSize: 42)),
                  ),
                ],
              ),
            ),
          );
        }

        return _HomePosterCarousel(
          posters: posters.map((doc) => doc.data()).toList(),
        );
      },
    );
  }

  Widget buildOfferStrip() {
    final offers = <Map<String, dynamic>>[
      {
        'icon': Icons.local_offer_rounded,
        'title': 'Offers for you',
        'subtitle': 'Check available discounts',
        'color': const Color(0xFFFFF0C2),
      },
      {
        'icon': Icons.delivery_dining_rounded,
        'title': 'Fast delivery',
        'subtitle': 'For serviceable addresses',
        'color': const Color(0xFFDDF4E4),
      },
      {
        'icon': Icons.shopping_basket_rounded,
        'title': 'Daily essentials',
        'subtitle': 'Groceries and more',
        'color': const Color(0xFFE3EEFF),
      },
    ];
    return SizedBox(
      height: 108,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        scrollDirection: Axis.horizontal,
        itemCount: offers.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final offer = offers[index];
          return Material(
            color: offer['color'] as Color,
            borderRadius: BorderRadius.circular(17),
            child: InkWell(
              borderRadius: BorderRadius.circular(17),
              onTap: () {
                setState(() {
                  if (index == 0) {
                    selectedCategory = 'All';
                    showDiscountedOnly = true;
                    searchText = '';
                    searchController.clear();
                    selectedTab = 0;
                  } else if (index == 1) {
                    selectedTab = 3;
                  } else {
                    showDiscountedOnly = false;
                    selectedCategory = 'All';
                    searchText = '';
                    searchController.clear();
                    selectedTab = 0;
                  }
                });
                if (index == 0) {
                  _showSnack(
                    'Discount वाले products देखने के लिए नीचे products देखें।',
                  );
                } else if (index == 1) {
                  _showSnack(
                    'Checkout पर delivery address और serviceability जाँचें।',
                  );
                }
              },
              child: Container(
                width: 228,
                padding: const EdgeInsets.all(10),
                child: Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.8),
                        borderRadius: BorderRadius.circular(13),
                      ),
                      child: Icon(
                        offer['icon'] as IconData,
                        color: const Color(0xFF3A342C),
                        size: 23,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            offer['title'] as String,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            offer['subtitle'] as String,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: Color(0xFF5D5D5D),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget buildCategories(List<String> categories) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,

      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 22, 16, 12),

          child: Text(
            'Shop by Category',

            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
        ),

        SizedBox(
          height: 88,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,

            padding: const EdgeInsets.symmetric(horizontal: 16),

            itemCount: categories.length,

            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (context, index) {
              final category = categories[index];

              final selected =
                  selectedCategory.toLowerCase() == category.toLowerCase();

              return GestureDetector(
                onTap: () => setState(() => selectedCategory = category),

                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),

                  width: 88,

                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: selected ? const Color(0xFFFFEBEE) : Colors.white,

                    borderRadius: BorderRadius.circular(18),

                    border: Border.all(
                      color: selected
                          ? const Color(0xFFE53935)
                          : Colors.transparent,

                      width: 1.4,
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,

                    children: [
                      Text(
                        _categoryEmoji(category),

                        style: const TextStyle(fontSize: 26),
                      ),

                      const SizedBox(height: 5),

                      Text(
                        category,

                        maxLines: 1,

                        overflow: TextOverflow.ellipsis,

                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,

                          color: selected
                              ? const Color(0xFFE53935)
                              : Colors.black87,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  String _categoryEmoji(String category) {
    final c = category.toLowerCase();

    if (c.contains('fruit')) return '🍎';
    if (c.contains('veget')) return '🥦';
    if (c.contains('dairy') || c.contains('milk')) return '🥛';
    if (c.contains('bakery')) return '🍞';
    if (c.contains('drink') || c.contains('beverage')) return '🥤';
    if (c.contains('snack')) return '🍪';
    if (c.contains('personal')) return '🧴';

    return '🛒';
  }

  Widget buildProductCard(Product product) {
    final isFavorite = favorites.contains(product.id);

    final hasDiscount =
        product.originalPrice > product.price && product.discount > 0;

    return GestureDetector(
      onTap: () => showProductDetails(product),

      child: Container(
        padding: const EdgeInsets.all(10),

        decoration: BoxDecoration(
          color: Colors.white,

          borderRadius: BorderRadius.circular(20),

          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.045),
              blurRadius: 12,
              offset: const Offset(0, 5),
            ),
          ],
        ),

        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,

          children: [
            Stack(
              children: [
                Container(
                  height: 132,

                  width: double.infinity,

                  decoration: BoxDecoration(
                    color: const Color(0xFFF7F7F7),

                    borderRadius: BorderRadius.circular(16),
                  ),

                  clipBehavior: Clip.antiAlias,

                  child: product.imageUrl.isNotEmpty
                      ? Image.network(
                          product.imageUrl,

                          fit: BoxFit.contain,

                          errorBuilder: (_, __, ___) => Center(
                            child: Text(
                              product.emoji,

                              style: const TextStyle(fontSize: 58),
                            ),
                          ),

                          loadingBuilder: (context, child, progress) {
                            if (progress == null) return child;
                            return const Center(
                              child: SizedBox(
                                width: 24,
                                height: 24,

                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            );
                          },
                        )
                      : Center(
                          child: Text(
                            product.emoji,

                            style: const TextStyle(fontSize: 58),
                          ),
                        ),
                ),
                if (hasDiscount)
                  Positioned(
                    left: 7,

                    top: 7,

                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,

                        vertical: 4,
                      ),

                      decoration: BoxDecoration(
                        color: const Color(0xFFE53935),
                        borderRadius: BorderRadius.circular(8),
                      ),

                      child: Text(
                        '${product.discount.toStringAsFixed(0)}% OFF',

                        style: const TextStyle(
                          color: Colors.white,

                          fontSize: 10,

                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ),

                Positioned(
                  right: 4,

                  top: 4,

                  child: Material(
                    color: Colors.white.withOpacity(0.92),

                    shape: const CircleBorder(),
                    child: IconButton(
                      visualDensity: VisualDensity.compact,

                      onPressed: () => toggleFavorite(product),

                      icon: Icon(
                        isFavorite ? Icons.favorite : Icons.favorite_border,
                        color: isFavorite ? Colors.red : Colors.grey.shade700,

                        size: 20,
                      ),
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 10),

            Text(
              product.name,

              maxLines: 1,

              overflow: TextOverflow.ellipsis,

              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
            ),

            const SizedBox(height: 3),

            Text(
              product.unit,
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),

            const SizedBox(height: 5),
            _ProductRatingLine(
              productId: product.id,
              fallbackAverage: product.ratingAverage,
              fallbackCount: product.ratingCount,
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                const Icon(
                  Icons.schedule_rounded,
                  size: 13,
                  color: Color(0xFF168A43),
                ),
                const SizedBox(width: 3),
                Text(
                  '${product.deliveryMinutes} mins',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF168A43),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 7),

            Row(
              crossAxisAlignment: CrossAxisAlignment.end,

              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,

                    children: [
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '₹${_money(product.price)}',
                          maxLines: 1,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                            color: Color(0xFF188A42),
                          ),
                        ),
                      ),

                      if (hasDiscount)
                        Text(
                          '₹${_money(product.originalPrice)}',

                          style: const TextStyle(
                            fontSize: 11,

                            color: Colors.grey,

                            decoration: TextDecoration.lineThrough,
                          ),
                        ),
                    ],
                  ),
                ),
                _ProductQuantityControl(
                  quantity:
                      cart.indexWhere((item) => item.product.id == product.id) <
                          0
                      ? 0
                      : cart[cart.indexWhere(
                              (item) => item.product.id == product.id,
                            )]
                            .quantity,
                  enabled: product.available && product.stock > 0,
                  onAdd: () => addToCart(product),
                  onIncrease: () {
                    final i = cart.indexWhere(
                      (item) => item.product.id == product.id,
                    );
                    if (i >= 0)
                      increaseQuantity(i);
                    else
                      addToCart(product);
                  },
                  onDecrease: () {
                    final i = cart.indexWhere(
                      (item) => item.product.id == product.id,
                    );
                    if (i >= 0) decreaseQuantity(i);
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _money(double value) =>
      value % 1 == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(2);

  void showProductDetails(Product product) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          final hasDiscount =
              product.originalPrice > product.price && product.discount > 0;
          return SizedBox(
            height: MediaQuery.of(sheetContext).size.height * 0.96,
            child: Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Center(
                          child: Container(
                            width: 42,
                            height: 5,
                            decoration: BoxDecoration(
                              color: Colors.grey.shade300,
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: IconButton(
                            onPressed: () => Navigator.pop(sheetContext),
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ),
                        Container(
                          height: 220,
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: const Color(0xFFF7F7F7),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: product.imageUrl.isNotEmpty
                              ? Image.network(
                                  product.imageUrl,
                                  fit: BoxFit.contain,
                                  errorBuilder: (_, __, ___) => Center(
                                    child: Text(
                                      product.emoji,
                                      style: const TextStyle(fontSize: 76),
                                    ),
                                  ),
                                )
                              : Center(
                                  child: Text(
                                    product.emoji,
                                    style: const TextStyle(fontSize: 76),
                                  ),
                                ),
                        ),
                        const SizedBox(height: 14),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                product.name,
                                style: const TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                            IconButton(
                              onPressed: () => toggleFavorite(product),
                              icon: Icon(
                                favorites.contains(product.id)
                                    ? Icons.favorite
                                    : Icons.favorite_border,
                                color: favorites.contains(product.id)
                                    ? Colors.red
                                    : Colors.grey,
                                size: 27,
                              ),
                            ),
                          ],
                        ),
                        Text(
                          product.unit,
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          product.description.trim().isNotEmpty
                              ? product.description.trim()
                              : 'इस प्रोडक्ट का विवरण अभी उपलब्ध नहीं है।',
                          style: const TextStyle(
                            fontSize: 14,
                            height: 1.45,
                            color: Color(0xFF555555),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 10,
                          runSpacing: 6,
                          children: [
                            Text(
                              '₹${_money(product.price)}',
                              style: const TextStyle(
                                fontSize: 27,
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF188A42),
                              ),
                            ),
                            if (hasDiscount)
                              Text(
                                '₹${_money(product.originalPrice)}',
                                style: const TextStyle(
                                  color: Colors.grey,
                                  decoration: TextDecoration.lineThrough,
                                  fontSize: 16,
                                ),
                              ),
                            if (hasDiscount)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 9,
                                  vertical: 5,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFFEBEE),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  '${product.discount.toStringAsFixed(0)}% OFF',
                                  style: const TextStyle(
                                    color: Color(0xFFE85D04),
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            const Icon(
                              Icons.schedule_rounded,
                              color: Color(0xFF168A43),
                              size: 17,
                            ),
                            const SizedBox(width: 5),
                            Text(
                              '${product.deliveryMinutes} mins delivery',
                              style: const TextStyle(
                                color: Color(0xFF168A43),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              product.stock > 0
                                  ? '${product.stock} in stock'
                                  : 'Out of stock',
                              style: TextStyle(
                                color: product.stock > 0
                                    ? Colors.green
                                    : Colors.red,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        _ProductReviewsSection(
                          productId: product.id,
                          productName: product.name,
                        ),
                        const SizedBox(height: 18),
                        _relatedProductsSection(
                          product,
                          sheetContext,
                          () => setSheetState(() {}),
                        ),
                        const SizedBox(height: 14),
                      ],
                    ),
                  ),
                ),
                // Sticky cart action stays visible even when the details are scrolled.
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(16, 5, 16, 5),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border(
                      top: BorderSide(color: Colors.grey.shade200),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.06),
                        blurRadius: 12,
                        offset: const Offset(0, -3),
                      ),
                    ],
                  ),
                  child: SafeArea(
                    top: false,
                    child: SizedBox(
                      height: 40,
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: product.available && product.stock > 0
                            ? () {
                                addToCart(product);
                                Navigator.of(sheetContext).pop();
                                if (mounted) setState(() => selectedTab = 3);
                              }
                            : null,
                        icon: const Icon(
                          Icons.shopping_cart_outlined,
                          size: 19,
                        ),
                        label: Text(
                          product.available && product.stock > 0
                              ? 'View Cart  •  ${quantityInCart(product) + 1}  •  ₹${_money(product.price)}'
                              : 'Out of Stock',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF1769E0),
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: Colors.grey.shade300,
                          elevation: 2,
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(13),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _relatedProductsSection(
    Product selectedProduct,
    BuildContext sheetContext,
    VoidCallback refreshSheet,
  ) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('products')
          .where('category', isEqualTo: selectedProduct.category)
          .snapshots(),
      builder: (context, snapshot) {
        final related = (snapshot.data?.docs ?? [])
            .where((doc) => doc.id != selectedProduct.id)
            .map(Product.fromFirestore)
            .where((item) => item.available && item.stock > 0)
            .take(9)
            .toList();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Similar products',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 10),
            if (snapshot.hasError)
              const Text(
                'Related products अभी load नहीं हो पाए।',
                style: TextStyle(color: Colors.grey),
              )
            else if (!snapshot.hasData)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(12),
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else if (related.isEmpty)
              const Text(
                'इस category में अभी दूसरे products उपलब्ध नहीं हैं।',
                style: TextStyle(color: Colors.grey),
              )
            else
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: related.length,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 12,
                  mainAxisExtent: 224,
                ),
                itemBuilder: (context, index) {
                  final item = related[index];
                  final cartIndex = cart.indexWhere(
                    (entry) => entry.product.id == item.id,
                  );
                  final quantity = cartIndex < 0 ? 0 : cart[cartIndex].quantity;

                  void openRelated() {
                    Navigator.pop(sheetContext);
                    Future<void>.delayed(const Duration(milliseconds: 250), () {
                      if (mounted) showProductDetails(item);
                    });
                  }

                  return Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF7F7F7),
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: InkWell(
                            borderRadius: BorderRadius.circular(9),
                            onTap: openRelated,
                            child: SizedBox(
                              width: double.infinity,
                              child: item.imageUrl.isNotEmpty
                                  ? Image.network(
                                      item.imageUrl,
                                      fit: BoxFit.contain,
                                      errorBuilder:
                                          (context, error, stackTrace) {
                                            return Center(
                                              child: Text(
                                                item.emoji,
                                                style: const TextStyle(
                                                  fontSize: 30,
                                                ),
                                              ),
                                            );
                                          },
                                    )
                                  : Center(
                                      child: Text(
                                        item.emoji,
                                        style: const TextStyle(fontSize: 30),
                                      ),
                                    ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 5),
                        InkWell(
                          onTap: openRelated,
                          child: Text(
                            item.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          item.unit,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 9,
                            color: Colors.grey,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '₹${_money(item.price)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                            _ProductQuantityControl(
                              quantity: quantity,
                              enabled: item.available && item.stock > 0,
                              onAdd: () {
                                addToCart(item);
                                refreshSheet();
                              },
                              onIncrease: () {
                                addToCart(item);
                                refreshSheet();
                              },
                              onDecrease: () {
                                final currentIndex = cart.indexWhere(
                                  (entry) => entry.product.id == item.id,
                                );
                                if (currentIndex >= 0) {
                                  decreaseQuantity(currentIndex);
                                  refreshSheet();
                                }
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
          ],
        );
      },
    );
  }

  Widget buildCart() {
    if (cart.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(30),

          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(25),
                decoration: const BoxDecoration(
                  color: Colors.white,

                  shape: BoxShape.circle,
                ),

                child: const Icon(
                  Icons.shopping_cart_outlined,

                  size: 65,

                  color: Colors.grey,
                ),
              ),
              const SizedBox(height: 18),

              const Text(
                'Your cart is empty',

                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 7),

              const Text(
                'Add your favourite groceries to continue.',

                textAlign: TextAlign.center,

                style: TextStyle(color: Colors.grey),
              ),

              const SizedBox(height: 20),

              ElevatedButton(
                onPressed: () => setState(() => selectedTab = 0),

                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFE53935),
                  foregroundColor: Colors.white,
                ),

                child: const Text('Start Shopping'),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        Container(
          width: double.infinity,

          padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),

          color: Colors.white,

          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'My Cart',

                  style: TextStyle(fontSize: 25, fontWeight: FontWeight.w900),
                ),
              ),

              Text(
                '$totalItems items',

                style: const TextStyle(
                  color: Colors.grey,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),

        Expanded(
          child: ListView.builder(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.all(16),

            itemCount: cart.length,

            itemBuilder: (context, index) {
              final item = cart[index];

              return Container(
                margin: const EdgeInsets.only(bottom: 12),

                padding: const EdgeInsets.all(11),

                decoration: BoxDecoration(
                  color: Colors.white,

                  borderRadius: BorderRadius.circular(18),
                ),

                child: Row(
                  children: [
                    Container(
                      width: 70,

                      height: 70,

                      decoration: BoxDecoration(
                        color: const Color(0xFFF7F7F7),

                        borderRadius: BorderRadius.circular(14),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: item.product.imageUrl.isNotEmpty
                          ? Image.network(
                              item.product.imageUrl,
                              fit: BoxFit.contain,

                              errorBuilder: (_, __, ___) => Center(
                                child: Text(
                                  item.product.emoji,

                                  style: const TextStyle(fontSize: 35),
                                ),
                              ),
                            )
                          : Center(
                              child: Text(
                                item.product.emoji,

                                style: const TextStyle(fontSize: 35),
                              ),
                            ),
                    ),
                    const SizedBox(width: 12),

                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,

                        children: [
                          Text(
                            item.product.name,

                            maxLines: 1,

                            overflow: TextOverflow.ellipsis,

                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 16,
                            ),
                          ),
                          Text(
                            item.product.unit,

                            style: const TextStyle(
                              color: Colors.grey,

                              fontSize: 12,
                            ),
                          ),

                          const SizedBox(height: 5),

                          Text(
                            '₹${_money(item.total)}',
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,

                              color: Color(0xFF188A42),

                              fontSize: 16,
                            ),
                          ),
                        ],
                      ),
                    ),

                    Row(
                      children: [
                        IconButton(
                          visualDensity: VisualDensity.compact,

                          onPressed: () => decreaseQuantity(index),

                          icon: const Icon(Icons.remove_circle_outline),
                        ),
                        Text(
                          '${item.quantity}',

                          style: const TextStyle(
                            fontWeight: FontWeight.w900,

                            fontSize: 16,
                          ),
                        ),

                        IconButton(
                          visualDensity: VisualDensity.compact,

                          onPressed: () => increaseQuantity(index),

                          icon: const Icon(
                            Icons.add_circle_outline,

                            color: Color(0xFFE53935),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),

          decoration: const BoxDecoration(
            color: Colors.white,

            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            boxShadow: [BoxShadow(blurRadius: 12, color: Color(0x12000000))],
          ),

          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,

                children: [
                  const Text(
                    'Total',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                  ),

                  Text(
                    '₹${_money(cartTotal)}',

                    style: const TextStyle(
                      fontSize: 23,

                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              SizedBox(
                width: double.infinity,

                height: 52,
                child: ElevatedButton(
                  onPressed: () => Navigator.push(
                    context,

                    MaterialPageRoute(
                      builder: (_) => CheckoutPage(
                        items: cart,
                        onOrderPlaced: () => setState(() => cart.clear()),
                      ),
                    ),
                  ),

                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFE53935),

                    foregroundColor: Colors.white,

                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(15),
                    ),
                  ),

                  child: const Text(
                    'Proceed to Checkout',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget buildProfile() {
    final user = currentUser;

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          const SizedBox(height: 18),
          Container(
            width: 100,

            height: 100,

            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                colors: [Color(0xFFE53935), Color(0xFFFF9F43)],
              ),

              boxShadow: [
                BoxShadow(
                  color: Colors.orange.withOpacity(0.22),

                  blurRadius: 18,
                ),
              ],
            ),
            child: profileImageBase64.isNotEmpty
                ? ClipOval(
                    child: Image.memory(
                      base64Decode(profileImageBase64),
                      width: 100,
                      height: 100,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const Icon(
                        Icons.person_rounded,
                        color: Colors.white,
                        size: 58,
                      ),
                    ),
                  )
                : const Icon(
                    Icons.person_rounded,
                    color: Colors.white,
                    size: 58,
                  ),
          ),

          const SizedBox(height: 14),

          Text(
            profileName.isEmpty ? 'FlashCart Account' : profileName,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 5),

          Text(
            user?.phoneNumber ?? 'Mobile account',
            style: const TextStyle(color: Colors.grey),
          ),

          const SizedBox(height: 10),
          _profileTile(
            Icons.edit_rounded,
            'Edit Profile',
            'Change your name or profile photo',
            _editCustomerProfile,
          ),

          const SizedBox(height: 25),

          _profileTile(
            Icons.receipt_long_rounded,
            'My Orders',

            'Track and view your orders',

            openOrders,
          ),

          const SizedBox(height: 10),
          _profileTile(
            Icons.favorite_rounded,

            'My Wishlist',

            '${favorites.length} saved products',

            () => _showWishlist(),
          ),

          const SizedBox(height: 10),

          _profileTile(
            Icons.location_on_rounded,

            'Delivery Address',
            'Manage address at checkout',

            () => _showAddressInfo(),
          ),

          const SizedBox(height: 10),

          _profileTile(
            Icons.support_agent_rounded,
            'Help & Support',

            'Customer helpline: 7488366915',

            () => _showHelp(),
          ),

          const SizedBox(height: 10),

          _profileTile(
            Icons.report_problem_rounded,
            'My Complaints',
            'Submit complaint with photo / screenshot',
            () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CustomerComplaintsPage()),
            ),
          ),

          const SizedBox(height: 10),

          _profileTile(
            Icons.logout_rounded,

            'Logout',
            'Sign out from this account',

            logout,

            danger: true,
          ),

          const SizedBox(height: 30),
          const Text(
            'FlashCart • Fresh groceries, fast delivery',

            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),

          const SizedBox(height: 10),
        ],
      ),
    );
  }

  Widget _profileTile(
    IconData icon,

    String title,

    String subtitle,

    VoidCallback onTap, {
    bool danger = false,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,

        borderRadius: BorderRadius.circular(18),
      ),

      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),

        leading: Container(
          padding: const EdgeInsets.all(10),

          decoration: BoxDecoration(
            color: danger
                ? Colors.red.withOpacity(0.08)
                : const Color(0xFFFFEBEE),

            borderRadius: BorderRadius.circular(12),
          ),

          child: Icon(
            icon,

            color: danger ? Colors.red : const Color(0xFFE53935),
          ),
        ),

        title: Text(
          title,

          style: TextStyle(
            fontWeight: FontWeight.w800,

            fontSize: 16,

            color: danger ? Colors.red : Colors.black87,
          ),
        ),

        subtitle: Text(subtitle),

        trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 16),
      ),
    );
  }

  void _showWishlist() {
    showModalBottomSheet(
      context: context,

      isScrollControlled: true,

      backgroundColor: Colors.white,

      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),

      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),

          child: Column(
            mainAxisSize: MainAxisSize.min,

            crossAxisAlignment: CrossAxisAlignment.start,

            children: [
              const Text(
                'My Wishlist',

                style: TextStyle(fontSize: 23, fontWeight: FontWeight.w900),
              ),

              const SizedBox(height: 8),

              Text(
                '${favorites.length} saved product${favorites.length == 1 ? '' : 's'}',
                style: const TextStyle(color: Colors.grey),
              ),

              const SizedBox(height: 14),
              if (favorites.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(25),

                  child: Center(child: Text('No favourite products yet.')),
                ),
              if (favorites.isNotEmpty) ...[
                const SizedBox(height: 5),

                const Text(
                  'Tap a product from Home to manage your favourites.',

                  style: TextStyle(color: Colors.grey),
                ),

                const SizedBox(height: 10),
              ],

              SizedBox(
                width: double.infinity,
                height: 48,

                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),

                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFE53935),
                    foregroundColor: Colors.white,
                  ),

                  child: const Text('Close'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showAddressInfo() {
    showModalBottomSheet(
      context: context,

      backgroundColor: Colors.white,

      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(22),

          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.location_on_rounded,

                size: 48,

                color: Color(0xFFE53935),
              ),

              const SizedBox(height: 10),

              const Text(
                'Delivery Address',

                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 7),

              const Text(
                'Your saved address can be added or changed securely during checkout.',
                textAlign: TextAlign.center,

                style: TextStyle(color: Colors.grey, height: 1.4),
              ),

              const SizedBox(height: 18),

              SizedBox(
                width: double.infinity,

                height: 48,

                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),

                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFE53935),

                    foregroundColor: Colors.white,
                  ),

                  child: const Text('Close'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showHelp() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,

      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),

      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(22),

          child: Column(
            mainAxisSize: MainAxisSize.min,

            crossAxisAlignment: CrossAxisAlignment.start,

            children: [
              const Text(
                'Help & Support',
                style: TextStyle(fontSize: 23, fontWeight: FontWeight.w900),
              ),

              const SizedBox(height: 7),

              const Text(
                'We are here to help with your FlashCart order.',
                style: TextStyle(color: Colors.grey),
              ),

              const SizedBox(height: 15),

              ListTile(
                contentPadding: EdgeInsets.zero,

                leading: const CircleAvatar(
                  backgroundColor: Color(0xFFFFEBEE),

                  child: Icon(Icons.phone, color: Color(0xFFE53935)),
                ),

                title: const Text(
                  'Customer Helpline',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),

                subtitle: const Text('7488366915'),
                trailing: IconButton(
                  onPressed: () {
                    Clipboard.setData(const ClipboardData(text: '7488366915'));

                    Navigator.pop(sheetContext);

                    _showSnack('Helpline number copied');
                  },

                  icon: const Icon(Icons.copy),
                ),
              ),

              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFFFFEBEE),
                  child: Icon(Icons.email_outlined, color: Color(0xFFE53935)),
                ),
                title: const Text(
                  'Support Email',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: const Text(flashCartSupportEmail),
                onTap: () {
                  Clipboard.setData(
                    const ClipboardData(text: flashCartSupportEmail),
                  );
                  Navigator.pop(sheetContext);
                  _showSnack('Support email copied');
                },
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,

                height: 48,

                child: ElevatedButton(
                  onPressed: () => Navigator.pop(sheetContext),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFE53935),

                    foregroundColor: Colors.white,
                  ),

                  child: const Text('Close'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ======================================================

// ======================================================
// CUSTOMER COMPLAINTS
// ======================================================
class CustomerComplaintsPage extends StatefulWidget {
  const CustomerComplaintsPage({super.key});

  @override
  State<CustomerComplaintsPage> createState() => _CustomerComplaintsPageState();
}

class _CustomerComplaintsPageState extends State<CustomerComplaintsPage> {
  final subjectController = TextEditingController();
  final descriptionController = TextEditingController();
  final orderController = TextEditingController();
  String category = 'Order / Delivery';
  bool submitting = false;
  String? attachmentBase64;
  String attachmentName = '';

  final categories = const [
    'Order / Delivery',
    'Product / Quality',
    'Payment',
    'Delivery Partner',
    'App / Login',
    'Other',
  ];

  @override
  void dispose() {
    subjectController.dispose();
    descriptionController.dispose();
    orderController.dispose();
    super.dispose();
  }

  Future<void> pickAttachment() async {
    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 55,
        maxWidth: 1400,
        maxHeight: 1400,
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (bytes.length > 700000) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Photo छोटा करें; maximum attachment लगभग 700 KB है',
              ),
            ),
          );
        }
        return;
      }
      setState(() {
        attachmentBase64 = base64Encode(bytes);
        attachmentName = file.name;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Photo select नहीं हो सका: $e')));
      }
    }
  }

  Future<void> submit() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final subject = subjectController.text.trim();
    final description = descriptionController.text.trim();
    if (subject.length < 3 || description.length < 10) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Subject और complaint details सही से भरें'),
        ),
      );
      return;
    }
    setState(() => submitting = true);
    try {
      await FirebaseFirestore.instance.collection('customerComplaints').add({
        'userId': user.uid,
        'userPhone': user.phoneNumber ?? '',
        'category': category,
        'subject': subject,
        'description': description,
        'orderId': orderController.text.trim(),
        'status': 'Pending',
        'attachmentBase64': attachmentBase64 ?? '',
        'attachmentName': attachmentName,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      if (!mounted) return;
      subjectController.clear();
      descriptionController.clear();
      orderController.clear();
      setState(() {
        attachmentBase64 = null;
        attachmentName = '';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Complaint submitted successfully ✓'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Complaint submit नहीं हुई: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'My Complaints',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DropdownButtonFormField<String>(
            initialValue: category,
            decoration: const InputDecoration(
              labelText: 'Category',
              border: OutlineInputBorder(),
            ),
            items: categories
                .map((x) => DropdownMenuItem(value: x, child: Text(x)))
                .toList(),
            onChanged: submitting
                ? null
                : (v) => setState(() => category = v ?? category),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: subjectController,
            maxLength: 80,
            decoration: const InputDecoration(
              labelText: 'Complaint Subject',
              border: OutlineInputBorder(),
            ),
          ),
          TextField(
            controller: orderController,
            decoration: const InputDecoration(
              labelText: 'Order ID (Optional)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: descriptionController,
            minLines: 5,
            maxLines: 8,
            maxLength: 1500,
            decoration: const InputDecoration(
              labelText: 'Describe your issue',
              border: OutlineInputBorder(),
            ),
          ),
          OutlinedButton.icon(
            onPressed: submitting ? null : pickAttachment,
            icon: const Icon(Icons.photo_camera_back_rounded),
            label: Text(
              attachmentName.isEmpty
                  ? 'Add Photo / Screenshot'
                  : 'Attached: $attachmentName',
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 52,
            child: ElevatedButton.icon(
              onPressed: submitting ? null : submit,
              icon: submitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.send_rounded),
              label: Text(submitting ? 'Submitting...' : 'Submit Complaint'),
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Complaint History',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 8),
          if (uid != null)
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: FirebaseFirestore.instance
                  .collection('customerComplaints')
                  .where('userId', isEqualTo: uid)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Text('Complaints load नहीं हुईं: ${snapshot.error}');
                }
                if (!snapshot.hasData) {
                  return const Padding(
                    padding: EdgeInsets.all(20),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final docs = [...snapshot.data!.docs];
                docs.sort((a, b) {
                  final at = a.data()['createdAt'];
                  final bt = b.data()['createdAt'];
                  if (at is Timestamp && bt is Timestamp)
                    return bt.compareTo(at);
                  return 0;
                });
                if (docs.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('अभी कोई complaint नहीं है'),
                  );
                }
                return Column(
                  children: docs.map((doc) {
                    final d = doc.data();
                    return Card(
                      child: ListTile(
                        leading: const Icon(Icons.support_agent_rounded),
                        title: Text(d['subject']?.toString() ?? 'Complaint'),
                        subtitle: Text(
                          '${d['category'] ?? 'Other'} • ${d['status'] ?? 'Pending'}',
                        ),
                        isThreeLine: true,
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

// PHONE AUTH PAGE

// ======================================================

class PhoneAuthPage extends StatefulWidget {
  const PhoneAuthPage({super.key});

  @override
  State<PhoneAuthPage> createState() => _PhoneAuthPageState();
}

class _PhoneAuthPageState extends State<PhoneAuthPage> {
  final TextEditingController _phoneController = TextEditingController();

  final TextEditingController _otpController = TextEditingController();

  final FirebaseAuth _auth = FirebaseAuth.instance;

  String _verificationId = '';

  bool _isOtpSent = false;

  bool _isLoading = false;

  // ====================================================
  // SEND OTP
  // ====================================================

  Future<void> _sendOtp() async {
    final phone = _phoneController.text.trim();

    if (phone.length != 10) {
      _showError('कृ पया 10 अंकों का मोबाइल नंबर डालें');

      return;
    }

    setState(() {
      _isLoading = true;
    });

    final phoneNumber = '+91$phone';

    try {
      await _auth.verifyPhoneNumber(
        phoneNumber: phoneNumber,

        verificationCompleted: (PhoneAuthCredential credential) async {
          try {
            await _auth.signInWithCredential(credential);

            if (mounted) {
              _showSuccess('Login successful        🎉');
            }
          } catch (e) {
            _showError('Login नहीं हो पाया');
          }
        },

        verificationFailed: (FirebaseAuthException e) {
          if (!mounted) return;

          setState(() {
            _isLoading = false;
          });

          _showError(e.message ?? 'OTP भेजने में समस्या हुई');
        },

        codeSent: (String verificationId, int? resendToken) {
          if (!mounted) return;

          setState(() {
            _isLoading = false;
            _isOtpSent = true;

            _verificationId = verificationId;
          });

          _showSuccess('OTP भेज दिया गया है   📱');
        },

        codeAutoRetrievalTimeout: (String verificationId) {
          _verificationId = verificationId;
        },
      );
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _isLoading = false;
      });

      _showError('कु छ समस्या हुई। फिर से कोशिश करें।');
    }
  }

  // ====================================================

  // VERIFY OTP
  // ====================================================

  Future<void> _verifyOtp() async {
    final otp = _otpController.text.trim();

    if (otp.length != 6) {
      _showError('कृ पया 6 अंकों का OTP डालें');

      return;
    }

    if (_verificationId.isEmpty) {
      _showError('पहले OTP भेजें');

      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      final credential = PhoneAuthProvider.credential(
        verificationId: _verificationId,

        smsCode: otp,
      );

      await _auth.signInWithCredential(credential);

      if (!mounted) return;

      _showSuccess('Login successful     🎉');
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;

      setState(() {
        _isLoading = false;
      });

      _showError(e.message ?? 'गलत OTP है');
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _isLoading = false;
      });
      _showError('OTP verification failed');
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,

        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green,

        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  void dispose() {
    _phoneController.dispose();

    _otpController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),

      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),

          child: Column(
            children: [
              const SizedBox(height: 50),

              Container(
                width: 95,

                height: 95,

                decoration: BoxDecoration(
                  color: const Color(0xFFFFEBEE),
                  borderRadius: BorderRadius.circular(28),
                ),

                child: const Icon(
                  Icons.shopping_bag_rounded,

                  size: 55,
                  color: Color(0xFFE53935),
                ),
              ),

              const SizedBox(height: 25),
              Text(
                _isOtpSent ? 'Enter OTP        🔐' : 'Welcome to FlashCart 👋',
                style: const TextStyle(
                  fontSize: 26,

                  fontWeight: FontWeight.bold,
                ),

                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 8),

              Text(
                _isOtpSent
                    ? 'आपके मोबाइल नंबर पर भेजा गया OTP डालें'
                    : 'मोबाइल नंबर से जल्दी Login करें',

                style: const TextStyle(color: Colors.grey, fontSize: 15),

                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 35),

              if (!_isOtpSent) buildMobileSection() else buildOtpSection(),
            ],
          ),
        ),
      ),
    );
  }

  Widget buildMobileSection() {
    return Column(
      children: [
        Align(
          alignment: Alignment.centerLeft,

          child: const Text(
            'Mobile Number',

            style: TextStyle(fontWeight: FontWeight.w600),
          ),
        ),

        const SizedBox(height: 8),

        TextField(
          controller: _phoneController,

          keyboardType: TextInputType.phone,

          maxLength: 10,

          decoration: InputDecoration(
            counterText: '',

            hintText: 'Enter 10 digit mobile number',

            prefixIcon: const Icon(Icons.phone_outlined),

            prefixText: '+91 ',

            filled: true,
            fillColor: Colors.white,

            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(15),

              borderSide: BorderSide.none,
            ),
          ),
        ),

        const SizedBox(height: 20),

        SizedBox(
          width: double.infinity,

          height: 54,

          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : ElevatedButton(
                  onPressed: _sendOtp,

                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFE53935),
                    foregroundColor: Colors.white,

                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(15),
                    ),
                  ),
                  child: const Text(
                    'Send OTP',

                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                ),
        ),
      ],
    );
  }

  Widget buildOtpSection() {
    return Column(
      children: [
        Align(
          alignment: Alignment.centerLeft,

          child: const Text(
            'OTP',

            style: TextStyle(fontWeight: FontWeight.w600),
          ),
        ),

        const SizedBox(height: 8),

        TextField(
          controller: _otpController,

          keyboardType: TextInputType.number,

          maxLength: 6,

          decoration: InputDecoration(
            counterText: '',
            hintText: 'Enter 6 digit OTP',

            prefixIcon: const Icon(Icons.lock_outline),

            filled: true,

            fillColor: Colors.white,

            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(15),

              borderSide: BorderSide.none,
            ),
          ),
        ),
        const SizedBox(height: 20),

        SizedBox(
          width: double.infinity,

          height: 54,

          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : ElevatedButton(
                  onPressed: _verifyOtp,

                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFE53935),

                    foregroundColor: Colors.white,

                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(15),
                    ),
                  ),

                  child: const Text(
                    'Verify OTP',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                ),
        ),

        const SizedBox(height: 10),

        TextButton(
          onPressed: () {
            setState(() {
              _isOtpSent = false;
              _otpController.clear();
            });
          },
          child: const Text(
            '← Change Mobile Number',

            style: TextStyle(
              color: Color(0xFFE53935),

              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }
}

// ======================================================

// CHECKOUT PAGE
// ======================================================

class CheckoutPage extends StatefulWidget {
  final List<CartItem> items;

  final VoidCallback onOrderPlaced;

  const CheckoutPage({
    super.key,

    required this.items,

    required this.onOrderPlaced,
  });
  @override
  State<CheckoutPage> createState() => _CheckoutPageState();
}

class _CheckoutPageState extends State<CheckoutPage> {
  String paymentMethod = 'Cash on Delivery';

  String savedAddress = '';

  String savedName = '';

  String savedPhone = '';

  String savedHouse = '';
  String savedCity = '';

  String savedPin = '';

  double? savedLatitude;
  double? savedLongitude;
  DateTime? savedLocationAt;

  bool isLoadingAddress = true;
  bool isGettingLocation = false;

  bool isPlacingOrder = false;

  final TextEditingController offerController = TextEditingController();
  bool offerChecking = false;
  String appliedOfferCode = '';
  String appliedOfferName = '';
  double appliedOfferPercent = 0;
  String offerMessage = '';

  double get offerDiscount {
    if (appliedOfferPercent <= 0) return 0;
    return (itemsTotal * appliedOfferPercent / 100).clamp(0, itemsTotal);
  }

  final TextEditingController nameController = TextEditingController();

  final TextEditingController phoneController = TextEditingController();

  final TextEditingController addressController = TextEditingController();

  final TextEditingController cityController = TextEditingController();

  final TextEditingController pinController = TextEditingController();
  User? get user => FirebaseAuth.instance.currentUser;

  // ====================================================
  // TOTALS

  // ====================================================

  double get itemsTotal {
    double total = 0;

    for (final item in widget.items) {
      total += item.total;
    }

    return total;
  }

  // Checkout fees: delivery is free; handling and packaging remain fixed.
  double get handlingProcessingFee => 9.0;

  double get packagingFee => 7.0;

  double get deliveryFee => 0.0;

  double get grandTotal {
    final value =
        itemsTotal +
        handlingProcessingFee +
        packagingFee +
        deliveryFee -
        offerDiscount;
    return value < 0 ? 0 : value;
  }

  Future<void> applyOffer() async {
    final code = offerController.text.trim().toUpperCase();
    if (code.isEmpty) {
      setState(() => offerMessage = 'Offer code डालें');
      return;
    }
    if (offerChecking) return;
    setState(() {
      offerChecking = true;
      offerMessage = '';
    });
    try {
      final snap = await FirebaseFirestore.instance
          .collection('offers')
          .where('active', isEqualTo: true)
          .get();
      QueryDocumentSnapshot<Map<String, dynamic>>? match;
      for (final doc in snap.docs) {
        final data = doc.data();
        final stored = (data['code'] ?? '').toString().trim().toUpperCase();
        if (stored == code) {
          match = doc;
          break;
        }
      }
      if (match == null) {
        setState(() {
          appliedOfferCode = '';
          appliedOfferName = '';
          appliedOfferPercent = 0;
          offerMessage = 'Invalid या inactive offer code';
        });
        return;
      }
      final data = match.data();
      final minOrder = (data['minOrder'] as num?)?.toDouble() ?? 0;
      final percent = (data['discountPercent'] as num?)?.toDouble() ?? 0;
      if (percent <= 0) {
        setState(() => offerMessage = 'यह offer अभी valid नहीं है');
        return;
      }
      if (itemsTotal < minOrder) {
        setState(
          () => offerMessage =
              'इस offer के लिए minimum order ₹${minOrder.toStringAsFixed(0)} है',
        );
        return;
      }
      setState(() {
        appliedOfferCode = code;
        appliedOfferName = (data['name'] ?? code).toString();
        appliedOfferPercent = percent.clamp(0, 100);
        offerMessage =
            'Offer applied ✓  ₹${offerDiscount.toStringAsFixed(0)} बचत';
      });
    } catch (e) {
      setState(() => offerMessage = 'Offer apply नहीं हो सका');
    } finally {
      if (mounted) setState(() => offerChecking = false);
    }
  }

  void removeOffer() {
    setState(() {
      appliedOfferCode = '';
      appliedOfferName = '';
      appliedOfferPercent = 0;
      offerMessage = '';
      offerController.clear();
    });
  }

  // ====================================================

  // INIT

  // ====================================================

  @override
  void initState() {
    super.initState();

    phoneController.text = user?.phoneNumber?.replaceFirst('+91', '') ?? '';

    loadSavedAddress();
  }

  // ====================================================

  // LOAD SAVED ADDRESS

  // ====================================================

  Future<void> loadSavedAddress() async {
    final currentUser = user;

    if (currentUser == null) {
      setState(() {
        isLoadingAddress = false;
      });

      return;
    }

    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUser.uid)
          .get();

      if (doc.exists) {
        final data = doc.data() ?? {};

        final address = data['address'];

        if (address is Map) {
          savedName = address['name']?.toString() ?? '';

          savedPhone = address['phone']?.toString() ?? '';

          savedHouse = address['house']?.toString() ?? '';

          savedCity = address['city']?.toString() ?? '';

          savedPin = address['pin']?.toString() ?? '';

          final latitude = address['latitude'];
          final longitude = address['longitude'];
          savedLatitude = latitude is num ? latitude.toDouble() : null;
          savedLongitude = longitude is num ? longitude.toDouble() : null;

          final locationAt = address['locationUpdatedAt'];
          if (locationAt is Timestamp) {
            savedLocationAt = locationAt.toDate();
          }

          savedAddress =
              '${savedName}, '
              '${savedHouse}, '
              '${savedCity} - '
              '${savedPin}';

          nameController.text = savedName;

          phoneController.text = savedPhone.isNotEmpty
              ? savedPhone
              : phoneController.text;

          addressController.text = savedHouse;
          cityController.text = savedCity;

          pinController.text = savedPin;
        }
      }
    } catch (e) {
      debugPrint('Address load error: $e');
    }

    if (!mounted) return;

    setState(() {
      isLoadingAddress = false;
    });
  }

  // ====================================================
  // USE CURRENT GPS LOCATION
  // ====================================================

  Future<void> useCurrentLocation() async {
    if (isGettingLocation) return;

    setState(() => isGettingLocation = true);

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Phone Location/GPS चालू करें, फिर दोबारा कोशिश करें',
            ),
          ),
        );
        await Geolocator.openLocationSettings();
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Location permission दें ताकि exact delivery location save हो सके',
            ),
          ),
        );
        if (permission == LocationPermission.deniedForever) {
          await Geolocator.openAppSettings();
        }
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      // Convert GPS coordinates into a readable address and autofill the
      // address fields. Name and mobile number are deliberately untouched.
      List<Placemark> placemarks = <Placemark>[];
      try {
        final geocodingService = Geocoding();
        placemarks = await geocodingService.placemarkFromCoordinates(
          position.latitude,
          position.longitude,
        );
      } catch (_) {
        // GPS coordinates can still be saved if reverse geocoding is
        // unavailable or the network/geocoding service fails.
      }

      if (!mounted) return;

      final place = placemarks.isNotEmpty ? placemarks.first : null;
      String cleanParts(Iterable<String?> parts) {
        final seen = <String>{};
        final values = <String>[];
        for (final part in parts) {
          final value = (part ?? '').trim();
          if (value.isEmpty) continue;
          final key = value.toLowerCase();
          if (seen.add(key)) values.add(value);
        }
        return values.join(', ');
      }

      final readableAddress = place == null
          ? ''
          : cleanParts([
              place.name,
              place.subLocality,
              place.thoroughfare,
              place.street,
            ]);
      final readableCity = place == null
          ? ''
          : cleanParts([place.subAdministrativeArea, place.locality]);
      final readablePin = place?.postalCode?.trim() ?? '';

      setState(() {
        savedLatitude = position.latitude;
        savedLongitude = position.longitude;
        savedLocationAt = position.timestamp;

        // Only replace address values when geocoding returned real data;
        // never insert placeholders such as "Na" or overwrite with blanks.
        if (readableAddress.isNotEmpty) {
          addressController.text = readableAddress;
        }
        if (readableCity.isNotEmpty) {
          cityController.text = readableCity;
        }
        if (RegExp(r'^\d{6}$').hasMatch(readablePin)) {
          pinController.text = readablePin;
        }
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            place == null
                ? 'GPS location selected. Address details could not be fetched; please check them manually.'
                : 'Current location selected and address fields filled ✓',
          ),
          backgroundColor: place == null ? Colors.orange : Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Location नहीं मिल सकी: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => isGettingLocation = false);
    }
  }

  // ====================================================

  // SAVE ADDRESS TO FIRESTORE
  // ====================================================

  Future<void> saveAddress() async {
    final currentUser = user;

    if (currentUser == null) {
      return;
    }

    final name = nameController.text.trim();
    final phone = phoneController.text.trim();

    final house = addressController.text.trim();

    final city = cityController.text.trim();

    final pin = pinController.text.trim();

    if (name.isEmpty || house.isEmpty || city.isEmpty || pin.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('कृ पया सभी जरूरी जानकारी भरें')),
      );

      return;
    }

    if (pin.length != 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('कृ पया सही 6 अंकों का PIN Code डालें')),
      );

      return;
    }

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUser.uid)
          .set({
            'phone': currentUser.phoneNumber ?? phone,
            'address': {
              'name': name,

              'phone': phone,

              'house': house,
              'city': city,

              'pin': pin,

              'latitude': savedLatitude,
              'longitude': savedLongitude,
              'locationUpdatedAt': FieldValue.serverTimestamp(),
              'updatedAt': FieldValue.serverTimestamp(),
            },
          }, SetOptions(merge: true));

      savedName = name;

      savedPhone = phone;

      savedHouse = house;

      savedCity = city;
      savedPin = pin;

      savedAddress = '$name, $house, $city - $pin';

      if (!mounted) return;

      setState(() {});

      Navigator.pop(context);

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Address saved successfully ✓'),

          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Address save नहीं हुआ: $e'),

          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // ====================================================
  // ADDRESS SHEET

  // ====================================================

  void showAddressSheet() {
    showModalBottomSheet(
      context: context,

      isScrollControlled: true,

      backgroundColor: Colors.white,

      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
      ),

      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,

            bottom: MediaQuery.of(context).viewInsets.bottom + 20,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,

              children: [
                Text(
                  savedAddress.isEmpty
                      ? 'Add Delivery Address'
                      : 'Change Delivery Address',

                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),

                const SizedBox(height: 14),

                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1FAF3),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFB7E2C0)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.my_location_rounded,
                            color: Color(0xFF188A42),
                          ),
                          const SizedBox(width: 9),
                          const Expanded(
                            child: Text(
                              'Exact Delivery Location',
                              style: TextStyle(fontWeight: FontWeight.w800),
                            ),
                          ),
                          if (savedLatitude != null && savedLongitude != null)
                            const Icon(
                              Icons.check_circle_rounded,
                              color: Color(0xFF188A42),
                            ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Text(
                        savedLatitude != null && savedLongitude != null
                            ? 'Location selected. Delivery partner will navigate to this point.'
                            : 'Use your current GPS location for accurate delivery.',
                        style: const TextStyle(
                          color: Colors.black54,
                          fontSize: 12.5,
                        ),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        height: 46,
                        child: ElevatedButton.icon(
                          onPressed: isGettingLocation
                              ? null
                              : useCurrentLocation,
                          icon: isGettingLocation
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.my_location_rounded),
                          label: Text(
                            isGettingLocation
                                ? 'Getting location...'
                                : savedLatitude != null
                                ? 'Update Current Location'
                                : 'Use Current Location',
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF188A42),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(13),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 18),

                buildAddressField(
                  nameController,

                  'Full Name',

                  Icons.person_outline,
                ),

                const SizedBox(height: 12),

                buildAddressField(
                  phoneController,
                  'Mobile Number',

                  Icons.phone_outlined,

                  keyboardType: TextInputType.phone,
                ),

                const SizedBox(height: 12),

                buildAddressField(
                  addressController,

                  'House / Street / Village',

                  Icons.home_outlined,

                  maxLines: 2,
                ),

                const SizedBox(height: 12),

                buildAddressField(
                  cityController,
                  'City / District',

                  Icons.location_city_outlined,
                ),

                const SizedBox(height: 12),

                buildAddressField(
                  pinController,

                  'PIN Code',

                  Icons.pin_drop_outlined,
                  keyboardType: TextInputType.number,
                ),

                const SizedBox(height: 20),

                SizedBox(
                  width: double.infinity,

                  height: 52,

                  child: ElevatedButton(
                    onPressed: saveAddress,

                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFE53935),

                      foregroundColor: Colors.white,

                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(15),
                      ),
                    ),

                    child: Text(
                      savedAddress.isEmpty ? 'Save Address' : 'Update Address',
                      style: const TextStyle(
                        fontSize: 18,

                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ====================================================

  // ADDRESS FIELD

  // ====================================================

  Widget buildAddressField(
    TextEditingController controller,

    String label,

    IconData icon, {

    TextInputType keyboardType = TextInputType.text,

    int maxLines = 1,
  }) {
    return TextField(
      controller: controller,

      keyboardType: keyboardType,
      maxLines: maxLines,

      decoration: InputDecoration(
        labelText: label,

        prefixIcon: Icon(icon),

        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  // ====================================================
  // BRANCH SERVICEABILITY (ADDED; EXISTING CHECKOUT FEATURES RETAINED)
  // ====================================================

  Future<Map<String, dynamic>?> _findServiceableBranch({
    required double customerLatitude,
    required double customerLongitude,
  }) async {
    // This query is intentionally limited to active branches. Firestore rules
    // must permit signed-in customers to read active branch documents.
    final snapshot = await FirebaseFirestore.instance
        .collection('branches')
        .where('active', isEqualTo: true)
        .get(const GetOptions(source: Source.server));

    Map<String, dynamic>? selected;
    double nearestDistance = double.infinity;

    for (final doc in snapshot.docs) {
      final data = doc.data();
      final rawLat = data['latitude'] ?? data['branchLatitude'];
      final rawLng = data['longitude'] ?? data['branchLongitude'];
      if (rawLat is! num || rawLng is! num) continue;
      if (data['locationSet'] == false) continue;

      final radiusRaw = data['serviceRadiusKm'];
      final configuredRadius = radiusRaw is num ? radiusRaw.toDouble() : 4.0;
      // Safety cap: no branch can serve beyond 4 KM, even if old data says otherwise.
      final radiusKm = configuredRadius.clamp(0.0, 4.0).toDouble();
      if (radiusKm <= 0 || data['active'] == false) continue;

      final distanceMeters = Geolocator.distanceBetween(
        customerLatitude,
        customerLongitude,
        rawLat.toDouble(),
        rawLng.toDouble(),
      );
      final distanceKm = distanceMeters / 1000.0;
      if (distanceKm <= radiusKm && distanceKm < nearestDistance) {
        nearestDistance = distanceKm;
        selected = <String, dynamic>{
          'branchId': doc.id,
          'branchName':
              data['branchName']?.toString() ??
              data['name']?.toString() ??
              'FlashCart Branch',
          'branchLatitude': rawLat.toDouble(),
          'branchLongitude': rawLng.toDouble(),
          'serviceRadiusKm': radiusKm,
          'deliveryDistanceKm': double.parse(distanceKm.toStringAsFixed(3)),
        };
      }
    }
    return selected;
  }

  // ====================================================
  // PLACE ORDER
  // ====================================================

  Future<void> placeOrder() async {
    // CEO-controlled order availability: check fresh server config before checkout.
    try {
      final availabilityDoc = await FirebaseFirestore.instance
          .collection('appConfig')
          .doc('businessAvailability')
          .get(const GetOptions(source: Source.server));
      final availability = availabilityDoc.data() ?? <String, dynamic>{};
      final accepting = availability['acceptingOrders'] != false;
      final scheduleEnabled = availability['scheduleEnabled'] == true;
      bool withinHours = true;

      if (scheduleEnabled) {
        int? parseMinutes(String? value) {
          if (value == null) return null;
          final parts = value.split(':');
          if (parts.length != 2) return null;
          final hour = int.tryParse(parts[0]);
          final minute = int.tryParse(parts[1]);
          if (hour == null ||
              minute == null ||
              hour < 0 ||
              hour > 23 ||
              minute < 0 ||
              minute > 59) {
            return null;
          }
          return hour * 60 + minute;
        }

        final start = parseMinutes(availability['openTime']?.toString());
        final end = parseMinutes(availability['closeTime']?.toString());
        if (start == null || end == null || start == end) {
          withinHours = false;
        } else {
          // Uses the device's local clock. Keep store/manager devices on India time.
          final now = DateTime.now();
          final current = now.hour * 60 + now.minute;
          // Supports schedules that cross midnight too.
          withinHours = start < end
              ? current >= start && current < end
              : current >= start || current < end;
        }
      }

      if (!accepting || !withinHours) {
        final message = availability['message']?.toString().trim();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              message == null || message.isEmpty
                  ? 'अभी नए ऑर्डर बंद हैं। कृपया बाद में प्रयास करें।'
                  : message,
            ),
          ),
        );
        return;
      }
    } catch (e) {
      // Fail closed if the latest order-control setting cannot be read.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'अभी ऑर्डर की उपलब्धता जाँची नहीं जा सकी। कृपया कुछ देर बाद प्रयास करें।',
          ),
        ),
      );
      return;
    }

    if (user == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Please login first')));

      return;
    }

    if (savedAddress.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please add delivery address')),
      );
      return;
    }

    if (savedLatitude == null || savedLongitude == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please set your current location for exact delivery'),
        ),
      );
      return;
    }

    if (widget.items.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Your cart is empty')));

      return;
    }

    if (paymentMethod != 'Cash on Delivery') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Online payment will be available soon. Please select Cash on Delivery.',
          ),
        ),
      );

      return;
    }

    if (widget.items.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Your cart is empty')));
      return;
    }

    Map<String, dynamic>? serviceBranch;
    try {
      serviceBranch = await _findServiceableBranch(
        customerLatitude: savedLatitude!,
        customerLongitude: savedLongitude!,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Delivery area check नहीं हो सका (${e.runtimeType})। '
            'Firestore Rules/branch data जाँचें और फिर कोशिश करें।',
          ),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 6),
        ),
      );
      return;
    }

    if (serviceBranch == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Unserviceable area: अभी आपके पते से 4 KM के अंदर कोई active FlashCart branch उपलब्ध नहीं है।',
          ),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 5),
        ),
      );
      return;
    }

    setState(() {
      isPlacingOrder = true;
    });

    try {
      // Keep a non-null local reference after the login guard above.
      // This fixes Dart nullable-analysis errors without changing behavior.
      final currentUser = user!;

      // Convert cart to Firestore data

      final orderItems = widget.items.map((item) {
        return {
          'productId': item.product.id,
          'name': item.product.name,
          'category': item.product.category,

          'unit': item.product.unit,

          'price': item.product.price,

          'quantity': item.quantity,

          'total': item.total,
          'emoji': item.product.emoji,

          'imageUrl': item.product.imageUrl,

          'originalPrice': item.product.originalPrice,

          'discount': item.product.discount,
        };
      }).toList();

      // Create the order and a small delivery-queue record together.
      // The queue record lets the delivery app claim new orders directly
      // without requiring the Admin app to be logged in.
      final db = FirebaseFirestore.instance;
      final orderRef = db.collection('orders').doc();
      final queueRef = db.collection('deliveryQueue').doc(orderRef.id);

      final batch = db.batch();
      batch.set(orderRef, {
        'orderId': orderRef.id,
        'userId': currentUser.uid,
        'userPhone': currentUser.phoneNumber ?? savedPhone,
        'customerName': savedName,
        'items': orderItems,
        'itemsTotal': itemsTotal,
        'handlingProcessingFee': handlingProcessingFee,
        'packagingFee': packagingFee,
        'deliveryFee': deliveryFee,
        'discountAmount': offerDiscount,
        'discountPercent': appliedOfferPercent,
        'appliedOfferCode': appliedOfferCode,
        'appliedOfferName': appliedOfferName,
        'totalPrice': grandTotal,
        'paymentMethod': paymentMethod,
        'deliveryAddress': savedAddress,
        'deliveryLatitude': savedLatitude,
        'deliveryLongitude': savedLongitude,
        'deliveryGeoPoint': GeoPoint(savedLatitude ?? 0, savedLongitude ?? 0),
        'deliveryLocationSet': true,
        'deliveryLocationUpdatedAt': FieldValue.serverTimestamp(),
        // Branch snapshot keeps existing order fields and adds serviceability metadata.
        'branchId': serviceBranch['branchId'],
        'branchName': serviceBranch['branchName'],
        'branchLatitude': serviceBranch['branchLatitude'],
        'branchLongitude': serviceBranch['branchLongitude'],
        'serviceRadiusKm': serviceBranch['serviceRadiusKm'],
        'deliveryDistanceKm': serviceBranch['deliveryDistanceKm'],
        'status': 'Order Placed',
        'orderDate': FieldValue.serverTimestamp(),
      });

      batch.set(queueRef, {
        'orderId': orderRef.id,
        'userId': currentUser.uid,
        'status': 'pending',
        'assignedPartnerId': '',
        'branchId': serviceBranch['branchId'],
        'branchName': serviceBranch['branchName'],
        'createdAt': FieldValue.serverTimestamp(),
      });

      await batch.commit();

      widget.onOrderPlaced();

      if (!mounted) return;
      Navigator.pushReplacement(
        context,

        MaterialPageRoute(
          builder: (_) => OrderSuccessPage(orderId: orderRef.id),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      setState(() {
        isPlacingOrder = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Order save नहीं हुआ: $e'),

          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  void dispose() {
    nameController.dispose();

    phoneController.dispose();

    addressController.dispose();

    cityController.dispose();
    pinController.dispose();
    offerController.dispose();
    super.dispose();
  }

  // ====================================================

  // CHECKOUT UI

  // ====================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),

      appBar: AppBar(
        title: const Text(
          'Checkout',

          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.white,
      ),

      body: isLoadingAddress
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),

              children: [
                const Text(
                  'Delivery Address',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),

                const SizedBox(height: 12),

                // =================================================

                // SAVED ADDRESS

                // =================================================
                Container(
                  padding: const EdgeInsets.all(16),

                  decoration: BoxDecoration(
                    color: Colors.white,

                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: savedAddress.isEmpty
                      ? InkWell(
                          onTap: showAddressSheet,

                          child: const Row(
                            children: [
                              Icon(Icons.location_on, color: Color(0xFFE53935)),

                              SizedBox(width: 12),

                              Expanded(
                                child: Text(
                                  'Add your delivery address',
                                  style: TextStyle(fontWeight: FontWeight.w600),
                                ),
                              ),

                              Icon(Icons.arrow_forward_ios, size: 16),
                            ],
                          ),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(
                                  Icons.location_on,

                                  color: Color(0xFFE53935),
                                ),

                                const SizedBox(width: 8),

                                const Expanded(
                                  child: Text(
                                    'Delivery Address',

                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,

                                      fontSize: 17,
                                    ),
                                  ),
                                ),

                                TextButton(
                                  onPressed: showAddressSheet,

                                  child: const Text(
                                    'Change',

                                    style: TextStyle(
                                      color: Color(0xFFE53935),

                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),

                            const Divider(),

                            const SizedBox(height: 5),

                            Text(
                              savedAddress,

                              style: const TextStyle(fontSize: 15, height: 1.5),
                            ),
                          ],
                        ),
                ),

                const SizedBox(height: 14),

                if (savedLatitude != null && savedLongitude != null)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(13),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF1FAF3),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Row(
                      children: [
                        Icon(
                          Icons.location_on_rounded,
                          color: Color(0xFF188A42),
                        ),
                        SizedBox(width: 9),
                        Expanded(
                          child: Text(
                            'Exact GPS delivery location is set',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        Icon(Icons.verified_rounded, color: Color(0xFF188A42)),
                      ],
                    ),
                  ),

                const SizedBox(height: 25),

                const Text(
                  'Payment Method',

                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),

                const SizedBox(height: 12),

                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),

                  child: Column(
                    children: [
                      RadioListTile<String>(
                        value: 'Cash on Delivery',

                        groupValue: paymentMethod,

                        onChanged: (value) {
                          setState(() {
                            paymentMethod = value!;
                          });
                        },

                        title: const Text('Cash on Delivery'),

                        secondary: const Icon(Icons.payments_outlined),
                      ),

                      RadioListTile<String>(
                        value: 'Online Payment',

                        groupValue: paymentMethod,
                        onChanged: null,

                        title: const Text('Online Payment (Coming soon)'),

                        secondary: const Icon(
                          Icons.account_balance_wallet_outlined,
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 25),

                // =================================================
                // OFFERS & COUPONS
                // =================================================
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Offers & Coupons',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 5),
                      const Text(
                        'Admin द्वारा बनाया गया active offer code यहाँ apply करें.',
                        style: TextStyle(color: Colors.grey, fontSize: 12.5),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: TextField(
                              controller: offerController,
                              textCapitalization: TextCapitalization.characters,
                              enabled: !offerChecking,
                              decoration: InputDecoration(
                                labelText: 'Offer Code',
                                hintText: 'e.g. FLASH20',
                                prefixIcon: const Icon(
                                  Icons.local_offer_outlined,
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          SizedBox(
                            height: 56,
                            child: FilledButton(
                              onPressed: offerChecking ? null : applyOffer,
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFFE53935),
                                foregroundColor: Colors.white,
                              ),
                              child: offerChecking
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Text('Apply'),
                            ),
                          ),
                        ],
                      ),
                      if (offerMessage.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          offerMessage,
                          style: TextStyle(
                            color: appliedOfferPercent > 0
                                ? Colors.green
                                : Colors.red,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                      if (appliedOfferCode.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            const Icon(
                              Icons.check_circle_rounded,
                              color: Colors.green,
                              size: 18,
                            ),
                            const SizedBox(width: 7),
                            Expanded(
                              child: Text(
                                '$appliedOfferCode applied • ${appliedOfferPercent.toStringAsFixed(0)}% off',
                                style: const TextStyle(
                                  color: Colors.green,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: offerChecking ? null : removeOffer,
                              child: const Text('Remove'),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),

                const SizedBox(height: 25),
                // =================================================

                // ORDER SUMMARY
                // =================================================
                Container(
                  padding: const EdgeInsets.all(18),

                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),

                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,

                        children: [
                          const Text('Items Total'),

                          Text('₹${itemsTotal.toStringAsFixed(0)}'),
                        ],
                      ),

                      const SizedBox(height: 10),

                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Handling & Processing Fee'),
                          Text('₹${handlingProcessingFee.toStringAsFixed(0)}'),
                        ],
                      ),

                      const SizedBox(height: 10),

                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Packaging Fee'),
                          Text('₹${packagingFee.toStringAsFixed(0)}'),
                        ],
                      ),

                      const SizedBox(height: 10),

                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Delivery Fee'),
                          const Text(
                            'FREE',
                            style: TextStyle(
                              color: Colors.green,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),

                      if (offerDiscount > 0) ...[
                        const SizedBox(height: 10),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Offer Discount'),
                            Text(
                              '-₹${offerDiscount.toStringAsFixed(0)}',
                              style: const TextStyle(
                                color: Colors.green,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ],

                      const Divider(height: 25),

                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,

                        children: [
                          const Text(
                            'Grand Total',

                            style: TextStyle(
                              fontWeight: FontWeight.bold,

                              fontSize: 18,
                            ),
                          ),

                          Text(
                            '₹${grandTotal.toStringAsFixed(0)}',

                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 20,

                              color: Color(0xFF188A42),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 25),

                SizedBox(
                  height: 54,

                  child: ElevatedButton(
                    onPressed: isPlacingOrder ? null : placeOrder,

                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFE53935),
                      foregroundColor: Colors.white,
                    ),

                    child: isPlacingOrder
                        ? const SizedBox(
                            width: 25,
                            height: 25,

                            child: CircularProgressIndicator(
                              color: Colors.white,

                              strokeWidth: 2,
                            ),
                          )
                        : const Text(
                            'Place Order',

                            style: TextStyle(
                              fontSize: 17,

                              fontWeight: FontWeight.bold,
                            ),
                          ),
                  ),
                ),

                const SizedBox(height: 25),
              ],
            ),
    );
  }
}

// ======================================================

// ORDER SUCCESS

// ======================================================

class OrderSuccessPage extends StatelessWidget {
  final String orderId;

  const OrderSuccessPage({super.key, required this.orderId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),

      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(25),

          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,

            children: [
              Container(
                width: 120,

                height: 120,

                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.10),

                  shape: BoxShape.circle,
                ),

                child: const Icon(
                  Icons.check_circle,

                  size: 100,

                  color: Colors.green,
                ),
              ),

              const SizedBox(height: 20),

              const Text(
                'Order Placed!',

                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
              ),

              const SizedBox(height: 10),
              Text(
                'Order #${orderId.substring(0, 8).toUpperCase()}',

                style: const TextStyle(
                  color: Colors.grey,

                  fontWeight: FontWeight.bold,
                ),
              ),

              const SizedBox(height: 10),

              const Text(
                'Your FlashCart order has been placed successfully.',
                textAlign: TextAlign.center,

                style: TextStyle(color: Colors.grey, fontSize: 16),
              ),

              const SizedBox(height: 10),

              const Text(
                'You can track your order from My Orders.',

                textAlign: TextAlign.center,

                style: TextStyle(color: Colors.grey),
              ),

              const SizedBox(height: 30),

              SizedBox(
                width: double.infinity,
                height: 52,

                child: ElevatedButton(
                  onPressed: () {
                    Navigator.popUntil(context, (route) => route.isFirst);
                  },

                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFE53935),

                    foregroundColor: Colors.white,
                  ),

                  child: const Text('Continue Shopping'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ======================================================

// MY ORDERS PAGE

// ======================================================

class MyOrdersPage extends StatelessWidget {
  const MyOrdersPage({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('My Orders')),

        body: const Center(child: Text('Please login first')),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),

      appBar: AppBar(
        backgroundColor: Colors.white,

        title: const Text(
          'My Orders',

          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),

      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('orders')
            .where('userId', isEqualTo: user.uid)
            .snapshots(),

        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(20),

                child: Text(
                  'Orders load नहीं हो पाए:\n${snapshot.error}',

                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          final docs = snapshot.data?.docs ?? [];

          // Newest first

          docs.sort((a, b) {
            final aData = a.data();

            final bData = b.data();

            final aTime = aData['orderDate'] as Timestamp?;

            final bTime = bData['orderDate'] as Timestamp?;

            if (aTime == null && bTime == null) {
              return 0;
            }
            if (aTime == null) {
              return 1;
            }

            if (bTime == null) {
              return -1;
            }

            return bTime.compareTo(aTime);
          });

          if (docs.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,

                children: [
                  Icon(
                    Icons.receipt_long_outlined,

                    size: 90,

                    color: Colors.grey,
                  ),

                  SizedBox(height: 15),

                  Text(
                    'No Orders Yet',

                    style: TextStyle(fontSize: 23, fontWeight: FontWeight.bold),
                  ),

                  SizedBox(height: 7),

                  Text(
                    'Your orders will appear here',
                    style: TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),

            itemCount: docs.length,

            itemBuilder: (context, index) {
              final data = docs[index].data();

              return buildOrderCard(context, docs[index].id, data);
            },
          );
        },
      ),
    );
  }

  // ====================================================

  // ORDER CARD

  // ====================================================

  Widget buildOrderCard(
    BuildContext context,

    String documentId,
    Map<String, dynamic> data,
  ) {
    final orderId = data['orderId']?.toString() ?? documentId;

    final status = data['status']?.toString() ?? 'Pending';

    final payment = data['paymentMethod']?.toString() ?? 'Cash on Delivery';

    final address = data['deliveryAddress']?.toString() ?? '';

    final total = data['totalPrice'];

    final items = data['items'] is List ? List.from(data['items']) : [];

    final timestamp = data['orderDate'] as Timestamp?;

    String dateText = 'Date not available';

    if (timestamp != null) {
      final date = timestamp.toDate();

      final day = date.day.toString().padLeft(2, '0');

      final month = date.month.toString().padLeft(2, '0');

      final year = date.year.toString();

      final hour = date.hour.toString().padLeft(2, '0');

      final minute = date.minute.toString().padLeft(2, '0');
      dateText = '$day/$month/$year • $hour:$minute';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 16),

      padding: const EdgeInsets.all(18),

      decoration: BoxDecoration(
        color: Colors.white,

        borderRadius: BorderRadius.circular(22),

        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 8),
        ],
      ),

      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,

        children: [
          // HEADER

          Row(
            children: [
              Container(
                width: 62,

                height: 62,

                alignment: Alignment.center,

                decoration: BoxDecoration(
                  color: const Color(0xFFFFEBEE),

                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.shopping_bag_rounded,

                  size: 34,

                  color: Color(0xFFE53935),
                ),
              ),

              const SizedBox(width: 12),

              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,

                  children: [
                    Text(
                      'Order #${orderId.length > 8 ? orderId.substring(0, 8).toUpperCase() : orderId.toUpperCase()}',

                      style: const TextStyle(
                        fontSize: 18,

                        fontWeight: FontWeight.bold,
                      ),
                    ),

                    const SizedBox(height: 5),

                    Text(dateText, style: const TextStyle(color: Colors.grey)),
                  ],
                ),
              ),

              orderStatusChip(status),
            ],
          ),
          const SizedBox(height: 18),

          const Divider(),

          const SizedBox(height: 8),

          // ITEMS
          ...items.map((item) {
            final itemMap = Map<String, dynamic>.from(item);

            final name = itemMap['name']?.toString() ?? '';

            final emoji = itemMap['emoji']?.toString() ?? '   🛒';
            final quantity = itemMap['quantity']?.toString() ?? '1';

            final itemTotal = itemMap['total'];

            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),

              child: Row(
                children: [
                  Text(emoji, style: const TextStyle(fontSize: 30)),

                  const SizedBox(width: 10),

                  Expanded(
                    child: Text(
                      '$name × $quantity',

                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),

                  Text(
                    '₹${formatAmount(itemTotal)}',

                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            );
          }),

          const Divider(),

          const SizedBox(height: 8),

          // TOTAL
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,

            children: [
              const Text(
                'Total Amount',

                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),

              Text(
                '₹${formatAmount(total)}',

                style: const TextStyle(
                  fontSize: 20,

                  fontWeight: FontWeight.bold,

                  color: Color(0xFF188A42),
                ),
              ),
            ],
          ),

          const SizedBox(height: 10),

          // PAYMENT
          Row(
            children: [
              const Icon(Icons.payments_outlined, size: 19, color: Colors.grey),

              const SizedBox(width: 7),

              Text(payment, style: const TextStyle(color: Colors.grey)),
            ],
          ),

          if (address.isNotEmpty) ...[
            const SizedBox(height: 10),

            Row(
              crossAxisAlignment: CrossAxisAlignment.start,

              children: [
                const Icon(
                  Icons.location_on_outlined,

                  size: 19,
                  color: Colors.grey,
                ),

                const SizedBox(width: 7),

                Expanded(
                  child: Text(
                    address,

                    style: const TextStyle(color: Colors.grey),
                  ),
                ),
              ],
            ),
          ],

          const SizedBox(height: 16),

          SizedBox(
            width: double.infinity,

            height: 48,

            child: ElevatedButton.icon(
              onPressed: () {
                Navigator.push(
                  context,

                  MaterialPageRoute(
                    builder: (_) => OrderTrackingPage(orderId: documentId),
                  ),
                );
              },

              icon: const Icon(Icons.location_on_outlined),

              label: const Text(
                'Track Order',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),

              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFE53935),

                foregroundColor: Colors.white,

                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),

          const SizedBox(height: 10),

          if (status.toLowerCase() != 'delivered' &&
              status.toLowerCase() != 'cancelled' &&
              status.toLowerCase() != 'out for delivery')
            SizedBox(
              width: double.infinity,

              height: 44,

              child: OutlinedButton.icon(
                onPressed: () => cancelOrder(context, documentId),

                icon: const Icon(Icons.close),
                label: const Text('Cancel Order'),

                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red,

                  side: const BorderSide(color: Colors.red),

                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> cancelOrder(BuildContext context, String documentId) async {
    final confirmed = await showDialog<bool>(
      context: context,

      builder: (dialogContext) => AlertDialog(
        title: const Text('Cancel Order?'),

        content: const Text('Are you sure you want to cancel this order?'),

        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('No'),
          ),

          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),

            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,

              foregroundColor: Colors.white,
            ),

            child: const Text('Yes, Cancel'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await FirebaseFirestore.instance
          .collection('orders')
          .doc(documentId)
          .update({
            'status': 'Cancelled',

            'cancelledAt': FieldValue.serverTimestamp(),
          });

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Order cancelled successfully'),

            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Order cancel नहीं हुआ: $e'),

            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // ====================================================

  // STATUS CHIP

  // ====================================================

  Widget orderStatusChip(String status) {
    Color textColor;

    Color backgroundColor;

    switch (status.toLowerCase()) {
      case 'delivered':
        textColor = Colors.green;

        backgroundColor = Colors.green.withOpacity(0.10);

        break;

      case 'cancelled':
        textColor = Colors.red;

        backgroundColor = Colors.red.withOpacity(0.10);

        break;

      case 'out for delivery':
        textColor = Colors.blue;

        backgroundColor = Colors.blue.withOpacity(0.10);

        break;
      case 'preparing':
        textColor = Colors.deepPurple;

        backgroundColor = Colors.deepPurple.withOpacity(0.10);
        break;

      case 'confirmed':
        textColor = Colors.teal;

        backgroundColor = Colors.teal.withOpacity(0.10);
        break;

      default:
        textColor = const Color(0xFFE09B00);

        backgroundColor = const Color(0xFFFFF5D6);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),

      decoration: BoxDecoration(
        color: backgroundColor,

        borderRadius: BorderRadius.circular(20),
      ),

      child: Text(
        status,
        style: TextStyle(
          color: textColor,

          fontWeight: FontWeight.bold,

          fontSize: 12,
        ),
      ),
    );
  }

  // ====================================================

  // FORMAT AMOUNT

  // ====================================================

  String formatAmount(dynamic value) {
    if (value == null) {
      return '0';
    }

    if (value is num) {
      return value.toDouble().toStringAsFixed(0);
    }

    return value.toString();
  }
}

// ======================================================

// ======================================================
// CUSTOMER DELIVERY PARTNER RATING
// One rating per delivered order; rating document ID is the order ID.
// ======================================================
class CustomerDeliveryRatingCard extends StatefulWidget {
  final String orderId;
  final Map<String, dynamic> orderData;
  final String partnerId;
  final String partnerName;

  const CustomerDeliveryRatingCard({
    super.key,
    required this.orderId,
    required this.orderData,
    required this.partnerId,
    required this.partnerName,
  });

  @override
  State<CustomerDeliveryRatingCard> createState() =>
      _CustomerDeliveryRatingCardState();
}

class _CustomerDeliveryRatingCardState
    extends State<CustomerDeliveryRatingCard> {
  int _stars = 5;
  bool _saving = false;
  final TextEditingController _reviewController = TextEditingController();

  @override
  void dispose() {
    _reviewController.dispose();
    super.dispose();
  }

  Future<void> _saveRating() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _message('Rating देने के लिए पहले login करें।');
      return;
    }
    if (_stars < 1 || _stars > 5) return;
    setState(() => _saving = true);
    final db = FirebaseFirestore.instance;
    final orderRef = db.collection('orders').doc(widget.orderId);
    final ratingRef = db.collection('deliveryRatings').doc(widget.orderId);
    try {
      await db.runTransaction((transaction) async {
        final orderSnap = await transaction.get(orderRef);
        final ratingSnap = await transaction.get(ratingRef);
        if (!orderSnap.exists) throw StateError('Order नहीं मिला।');
        final order = orderSnap.data() ?? <String, dynamic>{};
        if (order['userId']?.toString() != user.uid) {
          throw StateError('आप इस order की rating नहीं दे सकते।');
        }
        if (order['status']?.toString() != 'Delivered') {
          throw StateError(
            'Rating केवल delivery complete होने के बाद दे सकते हैं।',
          );
        }
        if (order['deliveryPartnerId']?.toString() != widget.partnerId) {
          throw StateError('Delivery partner की जानकारी match नहीं हुई।');
        }
        if (ratingSnap.exists)
          throw StateError('इस order की rating पहले ही दी जा चुकी है।');
        transaction.set(ratingRef, {
          'orderId': widget.orderId,
          'customerUid': user.uid,
          'customerName': widget.orderData['customerName']?.toString() ?? '',
          'partnerId': widget.partnerId,
          'partnerName': widget.partnerName,
          'branchId': order['branchId']?.toString() ?? '',
          'branchName': order['branchName']?.toString() ?? '',
          'stars': _stars,
          'review': _reviewController.text.trim(),
          'createdAt': FieldValue.serverTimestamp(),
        });
      });
      _message('धन्यवाद! आपकी rating सेव हो गई।');
    } catch (e) {
      _message(e.toString().replaceFirst('Bad state: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFFFE1A8)),
        boxShadow: [
          BoxShadow(
            color: Colors.orange.withOpacity(0.06),
            blurRadius: 14,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('deliveryRatings')
            .doc(widget.orderId)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Text('Rating अभी load नहीं हो सकी।');
          }
          if (snapshot.connectionState == ConnectionState.waiting &&
              !snapshot.hasData) {
            return const Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            );
          }
          final existing = snapshot.data?.data();
          if (existing != null) {
            final stars = (existing['stars'] as num?)?.toInt() ?? 0;
            final review = existing['review']?.toString() ?? '';
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.check_circle_rounded, color: Color(0xFF188A42)),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'आपकी rating दर्ज है',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: List.generate(
                    5,
                    (i) => Icon(
                      i < stars
                          ? Icons.star_rounded
                          : Icons.star_outline_rounded,
                      color: const Color(0xFFFFB800),
                      size: 28,
                    ),
                  ),
                ),
                if (review.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    review,
                    style: const TextStyle(color: Colors.black87, height: 1.4),
                  ),
                ],
              ],
            );
          }
          if (user == null ||
              widget.orderData['userId']?.toString() != user.uid) {
            return const SizedBox.shrink();
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.star_rounded, color: Color(0xFFFFB800), size: 28),
                  SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      'Rate your delivery partner',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'How was ${widget.partnerName}’s delivery?',
                style: const TextStyle(color: Colors.grey, fontSize: 13),
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(
                  5,
                  (index) => IconButton(
                    tooltip: '${index + 1} star${index == 0 ? '' : 's'}',
                    onPressed: _saving
                        ? null
                        : () => setState(() => _stars = index + 1),
                    icon: Icon(
                      index < _stars
                          ? Icons.star_rounded
                          : Icons.star_outline_rounded,
                      color: const Color(0xFFFFB800),
                      size: 35,
                    ),
                  ),
                ),
              ),
              Center(
                child: Text(
                  [
                    '',
                    'Poor',
                    'Fair',
                    'Good',
                    'Very good',
                    'Excellent',
                  ][_stars],
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _reviewController,
                maxLength: 300,
                maxLines: 2,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Write a review (optional)',
                  filled: true,
                  fillColor: const Color(0xFFFFFAF0),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(13),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _saving ? null : _saveRating,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF188A42),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
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
                      : const Icon(Icons.send_rounded),
                  label: Text(_saving ? 'Saving…' : 'Submit rating'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ORDER TRACKING PAGE

// ======================================================

class OrderTrackingPage extends StatelessWidget {
  final String orderId;

  const OrderTrackingPage({super.key, required this.orderId});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),

      appBar: AppBar(
        backgroundColor: Colors.white,

        title: const Text(
          'Track Order',

          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),

      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection('orders')
            .doc(orderId)
            .snapshots(),

        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(color: Color(0xFFE53935)),
            );
          }

          if (!snapshot.hasData || !snapshot.data!.exists) {
            return const Center(child: Text('Order not found'));
          }
          final data = snapshot.data!.data() as Map<String, dynamic>;

          final rawStatus = data['status']?.toString() ?? 'Order Placed';

          final status = rawStatus == 'Pending' ? 'Order Placed' : rawStatus;

          final deliveryPartnerName = data['deliveryPartnerName'] ?? '';

          final deliveryPartnerPhone = data['deliveryPartnerPhone'] ?? '';

          final estimatedDelivery =
              data['estimatedDelivery'] ?? '20-30 minutes';

          return ListView(
            padding: const EdgeInsets.all(16),

            children: [
              // ==================================================

              // ORDER HEADER

              // ==================================================
              Container(
                padding: const EdgeInsets.all(18),

                decoration: BoxDecoration(
                  color: Colors.white,

                  borderRadius: BorderRadius.circular(20),
                ),

                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Order #${orderId.length > 6 ? orderId.substring(0, 6).toUpperCase() : orderId.toUpperCase()}',
                      style: const TextStyle(
                        fontSize: 20,

                        fontWeight: FontWeight.bold,
                      ),
                    ),

                    const SizedBox(height: 8),

                    Text(
                      'Current Status: $status',

                      style: const TextStyle(
                        color: Color(0xFFE53935),

                        fontWeight: FontWeight.bold,
                      ),
                    ),

                    const SizedBox(height: 15),

                    Row(
                      children: [
                        const Icon(Icons.access_time, color: Colors.grey),

                        const SizedBox(width: 8),

                        Text(
                          'Estimated delivery: $estimatedDelivery',
                          style: const TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              // ==================================================

              // TRACKING TIMELINE

              // ==================================================
              Container(
                padding: const EdgeInsets.all(20),

                decoration: BoxDecoration(
                  color: Colors.white,

                  borderRadius: BorderRadius.circular(20),
                ),

                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,

                  children: [
                    const Text(
                      'Delivery Status',

                      style: TextStyle(
                        fontSize: 21,

                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 25),

                    buildTrackingStep(
                      title: 'Order Placed',

                      subtitle: 'Your order has been received',

                      icon: Icons.receipt_long,

                      active: isStatusActive(status, 'Order Placed'),

                      completed: isStatusCompleted(status, 'Order Placed'),
                    ),

                    buildLine(isStatusCompleted(status, 'Order Placed')),

                    buildTrackingStep(
                      title: 'Order Confirmed',

                      subtitle: 'Your order has been confirmed',

                      icon: Icons.check_circle_outline,

                      active: isStatusActive(status, 'Confirmed'),
                      completed: isStatusCompleted(status, 'Confirmed'),
                    ),

                    buildLine(isStatusCompleted(status, 'Confirmed')),

                    buildTrackingStep(
                      title: 'Preparing',

                      subtitle: 'Your groceries are being prepared',

                      icon: Icons.shopping_bag_outlined,

                      active: isStatusActive(status, 'Preparing'),

                      completed: isStatusCompleted(status, 'Preparing'),
                    ),

                    buildLine(isStatusCompleted(status, 'Preparing')),

                    buildTrackingStep(
                      title: 'Out for Delivery',

                      subtitle: 'Delivery partner is on the way',

                      icon: Icons.delivery_dining,
                      active: isStatusActive(status, 'Out for Delivery'),

                      completed: isStatusCompleted(status, 'Out for Delivery'),
                    ),

                    buildLine(isStatusCompleted(status, 'Out for Delivery')),

                    buildTrackingStep(
                      title: 'Delivered',

                      subtitle: 'Order delivered successfully   🎉',
                      icon: Icons.home,

                      active: status == 'Delivered',

                      completed: status == 'Delivered',
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              // ==================================================
              // DELIVERY PARTNER
              // ==================================================
              if (deliveryPartnerName.toString().isNotEmpty)
                Container(
                  padding: const EdgeInsets.all(18),

                  decoration: BoxDecoration(
                    color: Colors.white,

                    borderRadius: BorderRadius.circular(20),
                  ),

                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,

                    children: [
                      const Text(
                        'Delivery Partner',
                        style: TextStyle(
                          fontSize: 20,

                          fontWeight: FontWeight.bold,
                        ),
                      ),

                      const SizedBox(height: 15),

                      Row(
                        children: [
                          const CircleAvatar(
                            radius: 27,

                            backgroundColor: Color(0xFFFFEBEE),

                            child: Icon(
                              Icons.person,

                              color: Color(0xFFE53935),
                              size: 30,
                            ),
                          ),

                          const SizedBox(width: 12),

                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,

                              children: [
                                Text(
                                  deliveryPartnerName,

                                  style: const TextStyle(
                                    fontSize: 17,

                                    fontWeight: FontWeight.bold,
                                  ),
                                ),

                                if (deliveryPartnerPhone.toString().isNotEmpty)
                                  Text(
                                    deliveryPartnerPhone,

                                    style: const TextStyle(color: Colors.grey),
                                  ),
                              ],
                            ),
                          ),

                          if (deliveryPartnerPhone.toString().isNotEmpty)
                            IconButton(
                              onPressed: () {},

                              icon: const Icon(
                                Icons.phone,
                                color: Color(0xFFE53935),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),

              if (status == 'Delivered' &&
                  (data['deliveryPartnerId'] ?? '').toString().isNotEmpty) ...[
                const SizedBox(height: 16),
                CustomerDeliveryRatingCard(
                  orderId: orderId,
                  orderData: data,
                  partnerId: (data['deliveryPartnerId'] ?? '').toString(),
                  partnerName: deliveryPartnerName.toString().isEmpty
                      ? 'Delivery Partner'
                      : deliveryPartnerName.toString(),
                ),
              ],

              const SizedBox(height: 20),

              Container(
                padding: const EdgeInsets.all(16),

                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                ),

                child: Row(
                  children: [
                    const CircleAvatar(
                      backgroundColor: Color(0xFFFFEBEE),

                      child: Icon(
                        Icons.support_agent,

                        color: Color(0xFFE53935),
                      ),
                    ),
                    const SizedBox(width: 12),

                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,

                        children: [
                          Text(
                            'Need help?',

                            style: TextStyle(
                              fontWeight: FontWeight.bold,

                              fontSize: 16,
                            ),
                          ),

                          SizedBox(height: 3),

                          Text(
                            'Customer Helpline: 7488366915',

                            style: TextStyle(color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 30),
            ],
          );
        },
      ),
    );
  }

  // ======================================================

  // TRACKING STEP

  // ======================================================

  Widget buildTrackingStep({
    required String title,

    required String subtitle,

    required IconData icon,

    required bool active,

    required bool completed,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,

      children: [
        Container(
          width: 48,

          height: 48,

          decoration: BoxDecoration(
            color: completed || active
                ? const Color(0xFFFFEBEE)
                : Colors.grey.shade100,

            shape: BoxShape.circle,
          ),

          child: Icon(
            completed ? Icons.check : icon,
            color: completed || active ? const Color(0xFFE53935) : Colors.grey,
          ),
        ),

        const SizedBox(width: 15),

        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,

                style: TextStyle(
                  fontSize: 17,

                  fontWeight: FontWeight.bold,

                  color: completed || active ? Colors.black : Colors.grey,
                ),
              ),

              const SizedBox(height: 4),

              Text(
                subtitle,

                style: const TextStyle(color: Colors.grey, fontSize: 13),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ======================================================

  // LINE

  // ======================================================

  Widget buildLine(bool active) {
    return Container(
      margin: const EdgeInsets.only(left: 23, top: 4, bottom: 4),

      height: 30,

      width: 2,

      color: active ? const Color(0xFFE53935) : Colors.grey.shade300,
    );
  }

  // ======================================================

  // STATUS ORDER

  // ======================================================

  int statusIndex(String status) {
    const statuses = [
      'Order Placed',

      'Confirmed',

      'Preparing',

      'Out for Delivery',

      'Delivered',
    ];

    final index = statuses.indexOf(status);
    return index == -1 ? 0 : index;
  }

  bool isStatusActive(String currentStatus, String step) {
    return statusIndex(currentStatus) == statusIndex(step);
  }

  bool isStatusCompleted(String currentStatus, String step) {
    return statusIndex(currentStatus) >= statusIndex(step);
  }
}
