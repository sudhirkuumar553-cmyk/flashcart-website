import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

class PhoneAuthPage extends StatefulWidget {
  const PhoneAuthPage({super.key});

  @override
  State<PhoneAuthPage> createState() => _PhoneAuthPageState();
}

class _PhoneAuthPageState extends State<PhoneAuthPage> {
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _otpController = TextEditingController();

  final FirebaseAuth _auth = FirebaseAuth.instance;

  String _verificationId = "";
  bool _isOtpSent = false;
  bool _isLoading = false;

  // 1. मोबाइल नंबर पर OTP भेजने का फंक्शन
  void _sendOtp() async {
    if (_phoneController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("कृपया सही मोबाइल नंबर दर्ज करें")),
      );
      return;
    }

    setState(() {
      _isLoading = true;
    });

    // भारत का कंट्री कोड (+91) ऑटोमैटिक जोड़ रहे हैं
    String phoneNumber = "+91${_phoneController.text.trim()}";

    await _auth.verifyPhoneNumber(
      phoneNumber: phoneNumber,
      verificationCompleted: (PhoneAuthCredential credential) async {
        // अगर ऑटो-वेरीफाई हो जाता है
        await _auth.signInWithCredential(credential);
        _showSuccess("लॉगिन सफल रहा!");
      },
      verificationFailed: (FirebaseAuthException e) {
        setState(() {
          _isLoading = false;
        });
        _showError("ओटीपी भेजने में विफलता: ${e.message}");
      },
      codeSent: (String verificationId, int? resendToken) {
        setState(() {
          _isLoading = false;
          _isOtpSent = true;
          _verificationId = verificationId;
        });
        _showSuccess("ओटीपी आपके नंबर पर भेज दिया गया है");
      },
      codeAutoRetrievalTimeout: (String verificationId) {
        _verificationId = verificationId;
      },
    );
  }

  // 2. दर्ज किए गए OTP को वेरीफाई करने का फंक्शन
  void _verifyOtp() async {
    if (_otpController.text.trim().isEmpty) {
      _showError("कृपया ओटीपी दर्ज करें");
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      PhoneAuthCredential credential = PhoneAuthProvider.credential(
        verificationId: _verificationId,
        smsCode: _otpController.text.trim(),
      );

      // यूजर को साइन-इन कराना
      await _auth.signInWithCredential(credential);
      _showSuccess("लॉगिन पूरी तरह सफल रहा!");

      // यहाँ आप लॉगिन के बाद होम स्क्रीन पर जा सकते हैं:
      // Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => HomePage()));
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      _showError("गलत ओटीपी! कृपया फिर से जाँचें।");
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.green),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("फ़्लैशकार्ट लॉगिन"), centerTitle: true),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.shopping_cart, size: 80, color: Colors.blue),
                const SizedBox(height: 30),

                if (!_isOtpSent) ...[
                  // मोबाइल नंबर इनपुट स्क्रीन
                  const Text(
                    "अपना मोबाइल नंबर दर्ज करें",
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 15),
                  TextField(
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: "मोबाइल नंबर",
                      prefixText: "+91 ",
                    ),
                  ),
                  const SizedBox(height: 20),
                  _isLoading
                      ? const CircularProgressIndicator()
                      : ElevatedButton(
                          onPressed: _sendOtp,
                          style: ElevatedButton.styleFrom(
                            minimumSize: const Size(double.infinity, 50),
                          ),
                          child: const Text("ओटीपी भेजें"),
                        ),
                ] else ...[
                  // ओटीपी इनपुट स्क्रीन
                  const Text(
                    "ओटीपी दर्ज करें",
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 15),
                  TextField(
                    controller: _otpController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: "6 अंकों का ओटीपी",
                    ),
                  ),
                  const SizedBox(height: 20),
                  _isLoading
                      ? const CircularProgressIndicator()
                      : ElevatedButton(
                          onPressed: _verifyOtp,
                          style: ElevatedButton.styleFrom(
                            minimumSize: const Size(double.infinity, 50),
                            backgroundColor: Colors.green,
                          ),
                          child: const Text("सत्यापित करें (Verify)"),
                        ),
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _isOtpSent = false;
                      });
                    },
                    child: const Text("नंबर बदलें"),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
