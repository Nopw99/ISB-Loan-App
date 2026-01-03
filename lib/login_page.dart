import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'; // For kIsWeb, defaultTargetPlatform
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:math'; 
import 'dart:typed_data'; 
import 'dart:async'; 
// PointyCastle for the "Safety Net" fallback
import 'package:pointycastle/export.dart' as pc; 
// Dargon2 for Speed (When it works)
import 'package:dargon2_flutter/dargon2_flutter.dart'; 
import 'package:shared_preferences/shared_preferences.dart'; 
import 'auth_config.dart'; 
import 'main.dart'; 
import 'secrets.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

enum LoginMode { google, username, signup }

class _LoginPageState extends State<LoginPage> {
  LoginMode _mode = LoginMode.google;
  bool _isLoading = false;
  bool _isPasswordVisible = false; 
  bool _isHandlingAuth = false; 
  bool _isGoogleHovered = false;

  final _userController = TextEditingController();
  final _passController = TextEditingController();
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _emailController = TextEditingController();

  StreamSubscription? _authSubscription;

  @override
  void initState() {
    super.initState();
    _startListeningToAuth();
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    _userController.dispose();
    _passController.dispose();
    _firstNameController.dispose();
    _lastNameController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // 1. ULTIMATE DEBUGGING HASH ENGINE
  // ---------------------------------------------------------------------------

  // Helper for the MAIN THREAD (Dargon2)
  Salt _generateSalt() {
    // We can use Dart's native secure random here too for consistency
    final random = Random.secure();
    final saltBytes = Uint8List(16);
    for (int i = 0; i < 16; i++) saltBytes[i] = random.nextInt(256);
    return Salt(saltBytes.toList());
  }

  Future<String> _hashPassword(String password) async {
    try {
      // 1. Check for Insecure Context (Just a warning for logs)
      if (kIsWeb) {
        final uri = Uri.base;
        if (uri.scheme == 'http' && uri.host != 'localhost' && uri.host != '127.0.0.1') {
          print("⚠️ WARNING: Running on insecure HTTP. Dargon2 might fail.");
        }
      }

      // 2. Try Dargon2 (Fast Wasm)
      // Force fallback on Windows/Linux as they don't support the Wasm lib
      if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.linux)) {
         throw UnimplementedError("Native fallback required for Desktop");
      }

      final salt = _generateSalt(); 
      final result = await argon2.hashPasswordBytes(
        utf8.encode(password) as List<int>,
        salt: salt,
        iterations: 3,
        memory: 16384, 
        parallelism: 2,
        length: 32,
        type: Argon2Type.id,
        version: Argon2Version.V13,
      );
      return result.encodedString;

    } catch (e, stack) {
      print("🔴 DARGON2 FAILED: $e");
      
      // 3. ATTEMPT FALLBACK (Compute -> Isolate)
      try {
        print("🟡 Attempting PointyCastle Fallback...");
        return await compute(isolateHashPassword, password);
      } catch (e2) {
        print("🔴 FALLBACK FAILED: $e2");
        
        if (mounted) {
          _showDetailedError("Encryption Failed", 
            "Primary Error: $e\n\n"
            "Fallback Error: $e2\n\n"
            "Solution: Ensure you are using HTTPS or Localhost."
          );
        }
        throw Exception("Encryption totally failed.");
      }
    }
  }

  Future<bool> _verifyPassword(String password, String storedHash) async {
    try {
      if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.linux)) {
         throw UnimplementedError("Native fallback required");
      }
      return await argon2.verifyHashString(password, storedHash);
    } catch (e) {
      print("🔴 Verify Failed ($e). Using Fallback.");
      // If Verify fails, we must use the worker
      return await compute(isolateVerifyPassword, [password, storedHash]);
    }
  }

  void _showDetailedError(String title, String details) {
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title, style: const TextStyle(color: Colors.red)),
        content: SingleChildScrollView(
          child: Text(details, style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text("OK")),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 2. AUTH LOGIC
  // ---------------------------------------------------------------------------

  void _startListeningToAuth() {
    _authSubscription = googleSignIn.authenticationState.listen((credentials) async {
      if (credentials == null) return;
      if (_isHandlingAuth) return;
      _isHandlingAuth = true; 
      if (!mounted) return;
      setState(() => _isLoading = true);
      
      try {
        final String? idToken = credentials.idToken;
        if (idToken != null && idToken.isNotEmpty) {
           final userData = _decodeIdToken(idToken);
           await _saveLoginState('google', userData['name'], userData['email']);
           if (!mounted) return;
           _navigateToHome(userData);
        } 
      } catch (e) {
        if (mounted) setState(() => _isLoading = false);
        _isHandlingAuth = false;
      }
    });
  }

  Map<String, dynamic> _decodeIdToken(String token) {
    final parts = token.split('.');
    if (parts.length != 3) throw Exception('Invalid token');
    final payload = parts[1];
    String normalized = base64Url.normalize(payload);
    final String decoded = utf8.decode(base64Url.decode(normalized));
    final Map<String, dynamic> payloadMap = jsonDecode(decoded);
    return {
      'name': payloadMap['name'] ?? "Unknown",
      'email': payloadMap['email'] ?? "No Email",
      'id': payloadMap['sub'] ?? "",
      'custom_salary': 10000, 
    };
  }

  Future<void> _handleGoogleSignIn() async {
    setState(() => _isLoading = true);
    try {
      final credentials = await googleSignIn.signIn();
      if (credentials != null && !kIsWeb) {
        final String? idToken = credentials.idToken;
        if (idToken != null) {
           final userData = _decodeIdToken(idToken);
           await _saveLoginState('google', userData['name'], userData['email']);
           if (!mounted) return;
           _navigateToHome(userData);
        }
      }
    } catch (error) {
      _showError("Google Sign in failed: $error");
      setState(() => _isLoading = false);
    }
  }

  Future<void> _handleUsernameLogin() async {
    if (_userController.text.isEmpty || _passController.text.isEmpty) { _showError("Enter details"); return; }
    setState(() => _isLoading = true);
    try {
      final input = _userController.text.trim();
      final password = _passController.text;
      Map<String, dynamic>? userData;
      String username = input;

      if (input.contains('@')) {
         final doc = await _fetchUserByEmail(input);
         if (doc == null) throw "Invalid credentials";
         userData = doc;
         username = doc['name'].toString().split('/').last;
      } else {
         final url = Uri.parse('https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents/users/$input');
         final response = await http.get(url);
         if (response.statusCode != 200) throw "User not found";
         userData = jsonDecode(response.body);
      }

      final fields = userData!['fields'];
      
      bool verified = await _verifyPassword(password, fields['password_hash']?['stringValue'] ?? "");

      if (verified) {
        await _saveLoginState('username', "${fields['first_name']?['stringValue']} ${fields['last_name']?['stringValue']}", username);
        if(!mounted) return;
        _navigateToHome({
          'name': "${fields['first_name']?['stringValue']} ${fields['last_name']?['stringValue']}",
          'email': username,
          'id': username,
          'custom_salary': int.tryParse(fields['salary']?['integerValue'] ?? '10000') ?? 10000,
        });
      } else { throw "Invalid credentials"; }
    } catch (e) { 
      print("LOGIN ERROR: $e");
      if (e.toString().contains("Encryption totally failed")) return;
      _showError("Login failed: ${e.toString().split('\n').first}"); 
    } finally { 
      if(mounted) setState(() => _isLoading = false); 
    }
  }

  Future<void> _handleSignUp() async {
    if (_userController.text.isEmpty || _passController.text.isEmpty ||
        _firstNameController.text.isEmpty || _lastNameController.text.isEmpty ||
        _emailController.text.isEmpty) {
      _showError("Please fill in all fields");
      return;
    }
    setState(() => _isLoading = true);
    try {
      final username = _userController.text.trim();
      final password = _passController.text;
      final personalEmail = _emailController.text.trim();
      
      final checkUrl = Uri.parse('https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents/users/$username');
      final checkResponse = await http.get(checkUrl);
      if (checkResponse.statusCode == 200) throw "Username '$username' is already taken.";

      // THIS IS WHERE IT WILL FAIL AND TRIGGER FALLBACK
      String hashedPassword = await _hashPassword(password);
      
      final createUrl = Uri.parse('https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents/users/$username');
      final body = jsonEncode({
        "fields": {
          "first_name": {"stringValue": _firstNameController.text.trim()},
          "last_name": {"stringValue": _lastNameController.text.trim()},
          "username": {"stringValue": username},
          "personal_email": {"stringValue": personalEmail},
          "password_hash": {"stringValue": hashedPassword},
          "salary": {"integerValue": "10000"},
          "created_at": {"timestampValue": DateTime.now().toUtc().toIso8601String()},
        }
      });
      final createResponse = await http.patch(createUrl, body: body);
      if (createResponse.statusCode != 200) throw "Failed to create account: ${createResponse.body}";

      _showSuccess("Account created! Please login.");
      setState(() { _mode = LoginMode.username; _passController.clear(); _userController.text = username; });
    } catch (e) { 
      print("SIGNUP ERROR: $e");
      if (e.toString().contains("Encryption totally failed")) return;
      _showError("Error: ${e.toString().split('\n').first}"); 
    } finally { 
      if (mounted) setState(() => _isLoading = false); 
    }
  }

  Future<void> _saveLoginState(String type, String name, String email) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isLoggedIn', true);
    await prefs.setString('loginType', type);
    await prefs.setString('userName', name);
    await prefs.setString('userEmail', email);
  }

  Future<bool> _verifyUserEmail(String username, String email) async {
    try {
      final url = Uri.parse('https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents/users/$username');
      final response = await http.get(url);
      if (response.statusCode != 200) return false;
      final data = jsonDecode(response.body);
      String storedEmail = data['fields']['personal_email']?['stringValue'] ?? "";
      return storedEmail.trim().toLowerCase() == email.trim().toLowerCase();
    } catch (e) { return false; }
  }

  String _generateOTP() {
    var rng = Random();
    return (100000 + rng.nextInt(900000)).toString();
  }

  Future<bool> _sendEmailOTP(String toEmail, String code) async {
    final url = Uri.parse('https://api.emailjs.com/api/v1.0/email/send');
    try {
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json', 'Origin': 'http://localhost'},
        body: jsonEncode({
          'service_id': serviceId,
          'template_id': templateId,
          'user_id': publicKey,
          'template_params': {'email': toEmail, 'otp_code': code}
        }),
      );
      return response.statusCode == 200;
    } catch (e) { return false; }
  }

  Future<bool> _updatePasswordInFirestore(String username, String newPass) async {
    try {
      String newHash = await _hashPassword(newPass);
      final url = Uri.parse('https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents/users/$username?updateMask.fieldPaths=password_hash');
      final response = await http.patch(url, body: jsonEncode({ "fields": { "password_hash": {"stringValue": newHash} } }));
      return response.statusCode == 200;
    } catch (e) { return false; }
  }

  Future<Map<String, dynamic>?> _fetchUserByEmail(String email) async {
    final url = Uri.parse('https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents:runQuery');
    try {
      final response = await http.post(url, body: jsonEncode({
        "structuredQuery": {
          "from": [{"collectionId": "users"}],
          "where": {"fieldFilter": {"field": {"fieldPath": "personal_email"}, "op": "EQUAL", "value": {"stringValue": email}}},
          "limit": 1
        }
      }));
      if (response.statusCode != 200) return null;
      final List data = jsonDecode(response.body);
      if (data.isNotEmpty && data[0]['document'] != null) return data[0]['document'];
      return null;
    } catch (e) { return null; }
  }

  void _showForgotPasswordDialog() {
    final emailCtrl = TextEditingController();
    final otpCtrl = TextEditingController();
    final newPassCtrl = TextEditingController();
    
    String? foundUsername; 

    int step = 1; 
    bool isProcessing = false;
    String? generatedOtp;
    String? statusMessage;
    int resendTimer = 0;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setStateDialog) {
          void startTimer() {
            setStateDialog(() => resendTimer = 60);
            Future.doWhile(() async {
              await Future.delayed(const Duration(seconds: 1));
              if (resendTimer > 0) {
                if (context.mounted) setStateDialog(() => resendTimer--);
                return true;
              }
              return false;
            });
          }
          return AlertDialog(
            title: Text(step == 1 ? "Reset Password" : "Verify Your Email"),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (statusMessage != null) Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(statusMessage!, style: const TextStyle(color: Colors.red))),
                
                if (step == 1) ...[
                  const Text("Enter your personal email to receive a code."),
                  const SizedBox(height: 16),
                  TextField(controller: emailCtrl, decoration: const InputDecoration(labelText: "Personal Email", border: OutlineInputBorder())),
                ] else ...[
                  TextField(controller: otpCtrl, decoration: const InputDecoration(labelText: "6-Digit Code", border: OutlineInputBorder())),
                  const SizedBox(height: 10),
                  TextField(controller: newPassCtrl, obscureText: true, decoration: const InputDecoration(labelText: "New Password", border: OutlineInputBorder())),
                  const SizedBox(height: 10),
                  if (resendTimer <= 0) TextButton(onPressed: () async {
                     setStateDialog(() => isProcessing = true);
                     String code = _generateOTP();
                     bool sent = await _sendEmailOTP(emailCtrl.text, code);
                     if(sent) { generatedOtp=code; startTimer(); setStateDialog(() { isProcessing = false; statusMessage = "Resent!"; }); }
                     else { setStateDialog(() { isProcessing = false; statusMessage = "Failed to resend."; }); }
                  }, child: const Text("Resend Code"))
                  else Text("Resend in ${resendTimer}s", style: const TextStyle(color: Colors.grey))
                ],
                if (isProcessing) const Padding(padding: EdgeInsets.only(top: 16), child: CircularProgressIndicator()),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
              ElevatedButton(
                onPressed: isProcessing ? null : () async {
                  if (step == 1) {
                     setStateDialog(() { isProcessing = true; statusMessage = null; });
                     final userDoc = await _fetchUserByEmail(emailCtrl.text.trim());
                     if (userDoc != null) {
                       foundUsername = userDoc['name'].toString().split('/').last;
                       String code = _generateOTP();
                       bool sent = await _sendEmailOTP(emailCtrl.text, code);
                       if(sent) { generatedOtp = code; step=2; startTimer(); }
                       else { statusMessage = "Could not send email."; }
                     } else {
                       statusMessage = "Email not found.";
                     }
                     setStateDialog(() => isProcessing = false);
                  } else {
                     if(otpCtrl.text.trim() == generatedOtp) {
                       setStateDialog(() { isProcessing = true; statusMessage = null; });
                       if (foundUsername != null) {
                          bool success = await _updatePasswordInFirestore(foundUsername!, newPassCtrl.text);
                          if(success) {
                             if(!mounted) return;
                             Navigator.pop(context);
                             _showSuccess("Password reset successfully!");
                          } else {
                             statusMessage = "Update failed.";
                          }
                       }
                       setStateDialog(() => isProcessing = false);
                     } else {
                        setStateDialog(() => statusMessage = "Invalid Code");
                     }
                  }
                },
                child: Text(step == 1 ? "Send Code" : "Update"),
              )
            ],
          );
        }
      ),
    );
  }

  void _navigateToHome(Map<String, dynamic> userData) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (context) => MainPageController(userData: userData)),
    );
  }
  
  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red));
  }
  void _showSuccess(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.green));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Image.network(
                'https://www.isb.ac.th/wp-content/uploads/2019/08/ISB-Logo-Color.png',
                height: 120,
                errorBuilder: (c, e, s) => const Icon(Icons.school, size: 80),
              ),
              const SizedBox(height: 30),
              const Text("ISB Funds", style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
              const Text("Staff Loan Portal", style: TextStyle(fontSize: 16, color: Colors.grey)),
              const SizedBox(height: 40),

              if (_isLoading)
                Column(
                  children: [
                    const SizedBox(height: 20),
                    if (kIsWeb)
                      const Text(
                        "Encrypting credentials...\nPlease wait a moment.",
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: Colors.blue),
                      )
                    else
                      const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    TextButton.icon(
                      onPressed: () => setState(() => _isLoading = false),
                      icon: const Icon(Icons.close, color: Colors.red),
                      label: const Text("Cancel", style: TextStyle(color: Colors.red)),
                    )
                  ],
                )
              else if (_mode == LoginMode.google)
                _buildGooglePanel()
              else if (_mode == LoginMode.username)
                _buildUsernamePanel()
              else
                _buildSignUpPanel(),
            ],
          ),
        ),
      ),
    );
  }
  
  Widget _buildGooglePanel() {
    final Widget customButton = ElevatedButton.icon(
      onPressed: kIsWeb ? () {} : _handleGoogleSignIn, 
      icon: Image.network('https://upload.wikimedia.org/wikipedia/commons/thumb/c/c1/Google_%22G%22_logo.svg/1200px-Google_%22G%22_logo.svg.png', height: 24),
      label: const Text("Sign in with Google", style: TextStyle(fontSize: 16, color: Colors.black87, fontWeight: FontWeight.w600)),
      style: ElevatedButton.styleFrom(
        backgroundColor: _isGoogleHovered ? Colors.grey[200] : Colors.white,
        foregroundColor: Colors.black,
        elevation: _isGoogleHovered ? 5 : 3, 
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
        minimumSize: const Size(280, 50), 
      ),
    );

    return Column(
      children: [
        MouseRegion(
          onEnter: (_) => setState(() => _isGoogleHovered = true),
          onExit: (_) => setState(() => _isGoogleHovered = false),
          cursor: SystemMouseCursors.click, 
          child: SizedBox(
            width: 280,
            height: 50,
            child: kIsWeb
                ? Stack(children: [Center(child: customButton), Positioned.fill(child: Opacity(opacity: 0.01, child: googleSignIn.signInButton()))])
                : customButton,
          ),
        ),
        const SizedBox(height: 24),
        TextButton(onPressed: () => setState(() => _mode = LoginMode.username), child: const Text("Don't have a Google Email?", style: TextStyle(color: Colors.blue, fontWeight: FontWeight.bold)))
      ],
    );
  }

  Widget _buildUsernamePanel() {
    return Container(
      width: 350, padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(color: Colors.grey[50], borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.grey.shade200)),
      child: Column(children: [
          const Text("Staff Login", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 20),
          TextField(controller: _userController, decoration: const InputDecoration(labelText: "Username or Email", prefixIcon: Icon(Icons.person), border: OutlineInputBorder())),
          const SizedBox(height: 16),
          TextField(controller: _passController, obscureText: !_isPasswordVisible, decoration: InputDecoration(labelText: "Password", prefixIcon: const Icon(Icons.lock), border: const OutlineInputBorder(), suffixIcon: IconButton(icon: Icon(_isPasswordVisible ? Icons.visibility : Icons.visibility_off, color: Colors.grey), onPressed: () => setState(() => _isPasswordVisible = !_isPasswordVisible)))),
          const SizedBox(height: 8),
          Align(alignment: Alignment.centerRight, child: TextButton(onPressed: _showForgotPasswordDialog, child: const Text("Forgot Password?", style: TextStyle(color: Colors.grey, fontSize: 12)))),
          const SizedBox(height: 10),
          SizedBox(width: double.infinity, height: 45, child: ElevatedButton(onPressed: _handleUsernameLogin, style: ElevatedButton.styleFrom(backgroundColor: Colors.blue), child: const Text("Login", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)))),
          const SizedBox(height: 16),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              TextButton(onPressed: () => setState(() => _mode = LoginMode.google), child: const Text("Back", style: TextStyle(color: Colors.grey))),
              TextButton(onPressed: () { _userController.clear(); _passController.clear(); _firstNameController.clear(); _lastNameController.clear(); _emailController.clear(); setState(() => _mode = LoginMode.signup); }, child: const Text("Create Account", style: TextStyle(color: Colors.blue))),
          ])
      ]),
    );
  }

  Widget _buildSignUpPanel() {
    return Container(
      width: 350, padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(color: Colors.grey[50], borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.grey.shade200)),
      child: Column(children: [
          const Text("Create Account", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 20),
          Row(children: [Expanded(child: TextField(controller: _firstNameController, decoration: const InputDecoration(labelText: "First Name", border: OutlineInputBorder()))), const SizedBox(width: 12), Expanded(child: TextField(controller: _lastNameController, decoration: const InputDecoration(labelText: "Last Name", border: OutlineInputBorder())))]),
          const SizedBox(height: 16),
          TextField(controller: _emailController, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: "Personal Email (For Recovery)", prefixIcon: Icon(Icons.email), border: OutlineInputBorder())),
          const SizedBox(height: 16),
          TextField(controller: _userController, decoration: const InputDecoration(labelText: "Username", prefixIcon: Icon(Icons.person), border: OutlineInputBorder())),
          const SizedBox(height: 16),
          TextField(controller: _passController, obscureText: !_isPasswordVisible, decoration: InputDecoration(labelText: "Password", prefixIcon: const Icon(Icons.lock), border: const OutlineInputBorder(), suffixIcon: IconButton(icon: Icon(_isPasswordVisible ? Icons.visibility : Icons.visibility_off, color: Colors.grey), onPressed: () => setState(() => _isPasswordVisible = !_isPasswordVisible)))),
          const SizedBox(height: 24),
          SizedBox(width: double.infinity, height: 45, child: ElevatedButton(onPressed: _handleSignUp, style: ElevatedButton.styleFrom(backgroundColor: Colors.green), child: const Text("Sign Up", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)))),
          const SizedBox(height: 16),
          TextButton(onPressed: () => setState(() => _mode = LoginMode.username), child: const Text("Back to Login", style: TextStyle(color: Colors.grey))),
      ]),
    );
  }
}

// =============================================================================
// FALLBACK WORKERS (Fixed for Background Threads)
// =============================================================================

// 1. WORKER: Generate Hash (16 MB - Balanced)
String isolateHashPassword(String password) {
  // FIX: Use standard Dart Random instead of PointyCastle's SecureRandom
  // This prevents the 'LateInitializationError' in background threads.
  final random = Random.secure(); 
  final salt = Uint8List(16);
  for (int i = 0; i < 16; i++) salt[i] = random.nextInt(256);

  final parameters = pc.Argon2Parameters(
    pc.Argon2Parameters.ARGON2_id,
    salt,
    desiredKeyLength: 32,
    iterations: 3,
    memory: 30720, // 30 MB 
    lanes: 4,      
  );

  final argon2 = pc.Argon2BytesGenerator();
  argon2.init(parameters);

  final passwordBytes = utf8.encode(password) as Uint8List;
  final result = Uint8List(32);
  argon2.deriveKey(passwordBytes, 0, result, 0);

  String saltB64 = base64.encode(salt).replaceAll('=', '');
  String hashB64 = base64.encode(result).replaceAll('=', '');
  
  return "\$argon2id\$v=19\$m=16384,t=3,p=2\$$saltB64\$$hashB64";
}

// 2. WORKER: Verify Hash (Adaptive)
bool isolateVerifyPassword(List<String> args) {
  final password = args[0];
  final storedHash = args[1];

  try {
    final parts = storedHash.split('\$');
    if (parts.length < 5) return false;
    
    final paramsPart = parts[2]; 
    
    int memory = 30720; 
    int iterations = 3;
    int parallelism = 4;

    final paramSplits = paramsPart.split(',');
    for(var p in paramSplits) {
      if(p.startsWith('m=')) memory = int.parse(p.substring(2));
      if(p.startsWith('t=')) iterations = int.parse(p.substring(2));
      if(p.startsWith('p=')) parallelism = int.parse(p.substring(2));
    }

    String saltB64 = parts[4];
    String hashB64 = parts[5];

    while (saltB64.length % 4 != 0) saltB64 += '=';
    while (hashB64.length % 4 != 0) hashB64 += '=';

    final salt = base64.decode(saltB64);
    final originalHashBytes = base64.decode(hashB64);

    final parameters = pc.Argon2Parameters(
      pc.Argon2Parameters.ARGON2_id,
      salt,
      desiredKeyLength: 32,
      iterations: iterations,
      memory: memory, 
      lanes: parallelism, 
    );

    final argon2 = pc.Argon2BytesGenerator();
    argon2.init(parameters);

    final passwordBytes = utf8.encode(password) as Uint8List;
    final result = Uint8List(32);
    argon2.deriveKey(passwordBytes, 0, result, 0);

    for (int i = 0; i < result.length; i++) {
      if (result[i] != originalHashBytes[i]) return false;
    }
    return true;
  } catch (e) {
    return false;
  }
}