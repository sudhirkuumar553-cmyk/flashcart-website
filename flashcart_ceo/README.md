// Replace the existing CeoPartnerBankVerificationPage class with this class.
// Existing imports needed: dart:convert, package:http/http.dart as http,
// cloud_firestore, firebase_auth, flutter/material.dart.
// Existing helpers required: flashWeekKey, flashWeekStart, flashWeekEnd,
// flashDelivered, flashDeliveredDate, flashDeliveryEarning, flashMoney.
// This page supports both Admin and Delivery Partner bank profiles.

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
  String recipientType = 'deliveryPartner';

  void _msg(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(value), behavior: SnackBarBehavior.floating),
    );
  }

  String get _collection =>
      recipientType == 'admin' ? 'admins' : 'deliveryPartners';

  Future<void> _review(
    String uid,
    Map<String, dynamic> bank,
    bool approve,
  ) async {
    final note = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(approve ? 'Verify bank account?' : 'Reject bank account?'),
        content: TextField(
          controller: note,
          maxLines: 3,
          decoration: const InputDecoration(labelText: 'CEO note (optional)'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(approve ? 'Verify' : 'Reject'),
          ),
        ],
      ),
    );
    if (accepted != true) {
      note.dispose();
      return;
    }
    try {
      await db.collection(_collection).doc(uid).set({
        'payoutBank': {
          'verificationStatus': approve ? 'Verified' : 'Rejected',
          'verified': approve,
          'verifiedAt': approve ? FieldValue.serverTimestamp() : null,
          'verifiedBy': FirebaseAuth.instance.currentUser?.uid,
          'ceoNote': note.text.trim(),
          'reviewedAt': FieldValue.serverTimestamp(),
        },
        'bankVerificationUpdatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      _msg(approve ? 'Bank account verified.' : 'Bank account rejected.');
    } catch (e) {
      _msg('Verification update failed: $e');
    } finally {
      note.dispose();
    }
  }

  Future<String> _signedUrl(String path) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception('CEO login required.');
    final token = await user.getIdToken(true);
    const baseUrl = String.fromEnvironment('SUPABASE_URL');
    const publicKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
    if (token == null || baseUrl.isEmpty || publicKey.isEmpty) {
      throw Exception('Firebase token / Supabase build configuration missing.');
    }
    final response = await http.post(
      Uri.parse('$baseUrl/functions/v1/ceo-bank-document-url'),
      headers: {
        'apikey': publicKey,
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'path': path}),
    );
    final decoded = jsonDecode(response.body);
    if (response.statusCode != 200 ||
        decoded is! Map ||
        decoded['signedUrl'] == null) {
      throw Exception(
        decoded is Map ? decoded['error'] ?? 'Could not open document' :
            'Could not open document',
      );
    }
    return decoded['signedUrl'].toString();
  }

  Future<void> _viewDocument(String path) async {
    if (path.trim().isEmpty) {
      _msg('Document path is missing in Firestore.');
      return;
    }
    try {
      final url = await _signedUrl(path);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => Dialog(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Bank Document',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 520),
                  child: Image.network(
                    url,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) =>
                        const Text('Document could not be loaded.'),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Close'),
                ),
              ],
            ),
          ),
        ),
      );
    } catch (e) {
      _msg('Document open failed: $e');
    }
  }

  Future<void> _recordPayment(
    String uid,
    String branch,
    String name,
    Map<String, dynamic> bank,
    double suggestedAmount,
  ) async {
    final amount = TextEditingController(
      text: suggestedAmount.toStringAsFixed(2),
    );
    final utr = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Record manual payment • $name'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Bank: ${bank['bankName'] ?? '—'} • IFSC: ${bank['ifsc'] ?? '—'}'),
            TextField(
              controller: amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Amount actually paid ₹'),
            ),
            TextField(
              controller: utr,
              decoration: const InputDecoration(labelText: 'UTR / payment reference'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Record Paid'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      amount.dispose();
      utr.dispose();
      return;
    }
    final paid = double.tryParse(amount.text.trim()) ?? 0;
    final reference = utr.text.trim();
    if (paid <= 0 || reference.isEmpty) {
      _msg('Enter a valid paid amount and UTR.');
      amount.dispose();
      utr.dispose();
      return;
    }
    try {
      final week = flashWeekKey(DateTime.now());
      final id = '${recipientType}_${uid}_$week_${DateTime.now().millisecondsSinceEpoch}';
      await db.collection('weeklyPayouts').doc(id).set({
        'recipientUid': uid,
        'recipientType': recipientType,
        'branchId': branch,
        'weekKey': week,
        'weekStart': Timestamp.fromDate(flashWeekStart()),
        'amount': paid,
        'paidAmount': paid,
        'status': 'Paid',
        'paidAt': FieldValue.serverTimestamp(),
        'paidBy': FirebaseAuth.instance.currentUser?.uid,
        'paymentReference': reference,
        'bankVerifiedAt': bank['verifiedAt'],
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      _msg('Payment record saved with UTR. Transfer itself is manual.');
    } catch (e) {
      _msg('Payment record failed: $e');
    } finally {
      amount.dispose();
      utr.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: db.collection('branches').snapshots(),
      builder: (context, branchSnap) {
        if (branchSnap.hasError) return Center(child: Text('Branch error: ${branchSnap.error}'));
        if (!branchSnap.hasData) return const Center(child: CircularProgressIndicator());
        final branches = branchSnap.data!.docs;
        if (branches.isEmpty) return const Center(child: Text('No branches found.'));
        branchId ??= branches.first.id;
        if (!branches.any((b) => b.id == branchId)) branchId = branches.first.id;
        return ListView(
          padding: const EdgeInsets.all(14),
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [Color(0xFFFF6B35), Color(0xFFFF9F43)]),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text(
                'Bank Verification & Payments\nReview Admin and Delivery Partner bank details, documents and manual payment records.',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: branchId,
              decoration: const InputDecoration(labelText: 'Branch', border: OutlineInputBorder()),
              items: branches.map((b) => DropdownMenuItem(
                value: b.id,
                child: Text((b.data()['branchName'] ?? b.data()['storeName'] ?? b.id).toString()),
              )).toList(),
              onChanged: (value) => setState(() => branchId = value),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              value: recipientType,
              decoration: const InputDecoration(labelText: 'Account type', border: OutlineInputBorder()),
              items: const [
                DropdownMenuItem(value: 'deliveryPartner', child: Text('Delivery Partners')),
                DropdownMenuItem(value: 'admin', child: Text('Admins / Store Accounts')),
              ],
              onChanged: (value) => setState(() => recipientType = value ?? 'deliveryPartner'),
            ),
            const SizedBox(height: 12),
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: db.collection(_collection).where('branchId', isEqualTo: branchId).snapshots(),
              builder: (context, snap) {
                if (snap.hasError) return Text('Accounts load error: ${snap.error}');
                if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                if (snap.data!.docs.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('No accounts found for this branch. Check branchId in the profile documents.'),
                  );
                }
                return Column(
                  children: snap.data!.docs.map((doc) {
                    final data = doc.data();
                    final bank = Map<String, dynamic>.from(data['payoutBank'] is Map ? data['payoutBank'] : {});
                    final status = (bank['verificationStatus'] ?? 'Not submitted').toString();
                    final verified = status == 'Verified' && bank['verified'] == true;
                    final name = (data['name'] ?? data['fullName'] ?? data['storeName'] ?? data['branchName'] ?? 'Account').toString();
                    final path = (bank['documentPath'] ?? '').toString();
                    return Card(
                      margin: const EdgeInsets.only(bottom: 10),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Expanded(child: Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17))),
                              Chip(label: Text(status)),
                            ]),
                            Text('Bank: ${bank['bankName'] ?? '—'}'),
                            Text('Holder: ${bank['accountHolderName'] ?? '—'}'),
                            Text('Account: ${bank['accountNumber'] ?? '—'}'),
                            Text('IFSC: ${bank['ifsc'] ?? '—'} • UPI: ${bank['upiId'] ?? '—'}'),
                            if (path.isNotEmpty)
                              TextButton.icon(
                                onPressed: () => _viewDocument(path),
                                icon: const Icon(Icons.description_outlined),
                                label: Text('Open ${bank['documentName'] ?? 'cheque/passbook'}'),
                              ),
                            if ((bank['ceoNote'] ?? '').toString().isNotEmpty)
                              Text('CEO note: ${bank['ceoNote']}'),
                            Wrap(spacing: 8, children: [
                              OutlinedButton.icon(
                                onPressed: () => _review(doc.id, bank, false),
                                icon: const Icon(Icons.close),
                                label: const Text('Reject'),
                              ),
                              FilledButton.icon(
                                onPressed: () => _review(doc.id, bank, true),
                                icon: const Icon(Icons.verified),
                                label: const Text('Verify'),
                              ),
                              if (verified)
                                FilledButton.tonalIcon(
                                  onPressed: () => _recordPayment(doc.id, branchId!, name, bank, 0),
                                  icon: const Icon(Icons.payments_outlined),
                                  label: const Text('Record Payment'),
                                ),
                            ]),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                );
              },
            ),
            const SizedBox(height: 18),
            const Text('Recent payment history', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: db.collection('weeklyPayouts').where('branchId', isEqualTo: branchId).snapshots(),
              builder: (context, history) {
                if (history.hasError) return Text('History error: ${history.error}');
                if (!history.hasData) return const LinearProgressIndicator();
                final rows = history.data!.docs.where((x) =>
                  (x.data()['recipientType'] ?? '') == recipientType).toList()
                  ..sort((a,b) => ((b.data()['paidAt'] as Timestamp?)?.millisecondsSinceEpoch ?? 0)
                    .compareTo((a.data()['paidAt'] as Timestamp?)?.millisecondsSinceEpoch ?? 0));
                if (rows.isEmpty) return const Text('No payment history yet.');
                return Column(children: rows.take(30).map((row) {
                  final p = row.data();
                  return ListTile(
                    leading: const Icon(Icons.receipt_long),
                    title: Text('₹${flashMoney(p['paidAmount'] ?? p['amount']).toStringAsFixed(2)} • ${p['status'] ?? 'Pending'}'),
                    subtitle: Text('${p['recipientUid'] ?? ''} • UTR: ${p['paymentReference'] ?? '—'}'),
                  );
                }).toList());
              },
            ),
          ],
        );
      },
    );
  }
}
