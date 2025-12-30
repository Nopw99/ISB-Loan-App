import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:math'; 
import 'dart:typed_data'; 
// FIX: Hide 'State' and 'Padding' to prevent conflicts with Flutter
import 'package:pointycastle/export.dart' hide State, Padding; 
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
  
  // --- ADD THIS LINE ---
  bool _isPasswordVisible = false; 
  // --------------------

  final _userController = TextEditingController();
  final _passController = TextEditingController();
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _emailController = TextEditingController();

  // ---------------------------------------------------------------------------
  // 1. HELPER: SAVE LOGIN STATE
  // ---------------------------------------------------------------------------
  Future<void> _saveLoginState(String type, String name, String email) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isLoggedIn', true);
    await prefs.setString('loginType', type);
    await prefs.setString('userName', name);
    await prefs.setString('userEmail', email);
  }

  // ---------------------------------------------------------------------------
  // 2. HELPER: CRYPTO (Argon2id)
  // ---------------------------------------------------------------------------
  String _hashPassword(String password) {
    final random = Random.secure();
    final salt = Uint8List(16);
    for (int i = 0; i < 16; i++) salt[i] = random.nextInt(256);

    final parameters = Argon2Parameters(
      Argon2Parameters.ARGON2_id,
      salt,
      desiredKeyLength: 32,
      iterations: 2,
      memory: 65536, 
      lanes: 1, 
    );

    final argon2 = Argon2BytesGenerator();
    argon2.init(parameters);

    final passwordBytes = utf8.encode(password) as Uint8List;
    final result = Uint8List(32);
    argon2.deriveKey(passwordBytes, 0, result, 0);

    String saltB64 = base64.encode(salt).replaceAll('=', '');
    String hashB64 = base64.encode(result).replaceAll('=', '');
    return "\$argon2id\$v=19\$m=65536,t=2,p=1\$$saltB64\$$hashB64";
  }

  bool _verifyPassword(String password, String storedHash) {
    try {
      final parts = storedHash.split('\$');
      if (parts.length < 5) return false;
      
      String saltB64 = parts[4];
      String hashB64 = parts[5];

      while (saltB64.length % 4 != 0) saltB64 += '=';
      while (hashB64.length % 4 != 0) hashB64 += '=';

      final salt = base64.decode(saltB64);
      final originalHashBytes = base64.decode(hashB64);

      final parameters = Argon2Parameters(
        Argon2Parameters.ARGON2_id,
        salt,
        desiredKeyLength: 32,
        iterations: 2,
        memory: 65536,
        lanes: 1, 
      );

      final argon2 = Argon2BytesGenerator();
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

  // ---------------------------------------------------------------------------
  // 3. HELPER: PASSWORD RESET (EmailJS)
  // ---------------------------------------------------------------------------

  // A. Check if User Exists & Email Matches
  Future<bool> _verifyUserEmail(String username, String email) async {
    try {
      final url = Uri.parse('https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents/users/$username');
      final response = await http.get(url);
      if (response.statusCode != 200) return false;

      final data = jsonDecode(response.body);
      String storedEmail = data['fields']['personal_email']?['stringValue'] ?? "";
      
      return storedEmail.trim().toLowerCase() == email.trim().toLowerCase();
    } catch (e) {
      return false;
    }
  }

  // B. Generate 6-Digit Code
  String _generateOTP() {
    var rng = Random();
    return (100000 + rng.nextInt(900000)).toString();
  }

  // C. Send via EmailJS
  Future<bool> _sendEmailOTP(String toEmail, String code) async {

    final url = Uri.parse('https://api.emailjs.com/api/v1.0/email/send');
    
    try {
      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Origin': 'http://localhost', 
        },
        body: jsonEncode({
          'service_id': serviceId,
          'template_id': templateId,
          'user_id': publicKey,
          'template_params': {
            'email': toEmail, // Matches {{email}} in template
            'otp_code': code, // Matches {{otp_code}} in template
          }
        }),
      );
      
      // For debugging
      if (response.statusCode != 200) {
        print("EmailJS Error: ${response.body}");
      }
      return response.statusCode == 200;
    } catch (e) {
      print("Email Error: $e");
      return false;
    }
  }

  // D. Update Password in Database
  Future<bool> _updatePasswordInFirestore(String username, String newPass) async {
    try {
      String newHash = _hashPassword(newPass);
      final url = Uri.parse('https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents/users/$username?updateMask.fieldPaths=password_hash');
      
      final response = await http.patch(
        url,
        body: jsonEncode({ "fields": { "password_hash": {"stringValue": newHash} } })
      );
      
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  // E. Show Dialog
  void _showForgotPasswordDialog() {
    final usernameCtrl = TextEditingController();
    final emailCtrl = TextEditingController();
    final otpCtrl = TextEditingController();
    final newPassCtrl = TextEditingController();

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
                if (context.mounted) {
                  setStateDialog(() => resendTimer--);
                }
                return true;
              }
              return false;
            });
          }

          return AlertDialog(
            title: Text(step == 1 ? "Reset Password" : "Verify Your Email"),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (statusMessage != null)
                   Padding(
                     padding: const EdgeInsets.only(bottom: 10),
                     child: Text(statusMessage!, style: const TextStyle(color: Colors.red, fontSize: 13)),
                   ),

                if (step == 1) ...[
                  const Text("Enter your username and the personal email you registered with."),
                  const SizedBox(height: 16),
                  TextField(controller: usernameCtrl, decoration: const InputDecoration(labelText: "Username", border: OutlineInputBorder())),
                  const SizedBox(height: 10),
                  TextField(controller: emailCtrl, decoration: const InputDecoration(labelText: "Personal Email", border: OutlineInputBorder())),
                ],

                if (step == 2) ...[
                  Text("We sent a 6-digit code to ${emailCtrl.text}"),
                  const SizedBox(height: 16),
                  TextField(
                    controller: otpCtrl, 
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    decoration: const InputDecoration(labelText: "6-Digit Code", border: OutlineInputBorder(), counterText: ""),
                  ),
                  const SizedBox(height: 10),
                  TextField(controller: newPassCtrl, obscureText: true, decoration: const InputDecoration(labelText: "New Password", border: OutlineInputBorder())),
                  const SizedBox(height: 10),
                  
                  if (resendTimer > 0)
                    Text("Resend code in ${resendTimer}s", style: const TextStyle(color: Colors.grey, fontSize: 12))
                  else
                    TextButton(
                      onPressed: () async {
                        setStateDialog(() { isProcessing = true; });
                        String code = _generateOTP();
                        bool sent = await _sendEmailOTP(emailCtrl.text, code);
                        if (sent) {
                          generatedOtp = code;
                          startTimer();
                          setStateDialog(() { isProcessing = false; statusMessage = "Code resent!"; });
                        } else {
                          setStateDialog(() { isProcessing = false; statusMessage = "Failed to resend."; });
                        }
                      },
                      child: const Text("Didn't get a code? Resend"),
                    ),
                ],
                if (isProcessing) const Padding(padding: EdgeInsets.only(top: 16), child: CircularProgressIndicator()),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
              if (step == 1)
                ElevatedButton(
                  onPressed: isProcessing ? null : () async {
                    setStateDialog(() { isProcessing = true; statusMessage = null; });
                    bool exists = await _verifyUserEmail(usernameCtrl.text, emailCtrl.text);
                    if (!exists) {
                       setStateDialog(() { isProcessing = false; statusMessage = "Details don't match our records."; });
                       return;
                    }
                    String code = _generateOTP();
                    bool sent = await _sendEmailOTP(emailCtrl.text, code);
                    if (sent) {
                      generatedOtp = code;
                      startTimer();
                      setStateDialog(() { step = 2; isProcessing = false; });
                    } else {
                      setStateDialog(() { isProcessing = false; statusMessage = "Email failed to send."; });
                    }
                  },
                  child: const Text("Send Code"),
                ),
              if (step == 2)
                ElevatedButton(
                  onPressed: isProcessing ? null : () async {
                     if (otpCtrl.text.trim() != generatedOtp) {
                        setStateDialog(() => statusMessage = "Invalid code.");
                        return;
                     }
                     setStateDialog(() { isProcessing = true; statusMessage = null; });
                     bool success = await _updatePasswordInFirestore(usernameCtrl.text, newPassCtrl.text);
                     
                     if (success) {
                       if (!mounted) return;
                       Navigator.pop(context);
                       _showSuccess("Password reset successful!");
                     } else {
                       setStateDialog(() { isProcessing = false; statusMessage = "Error updating password."; });
                     }
                  },
                  child: const Text("Update Password"),
                ),
            ],
          );
        }
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 4. MAIN LOGIN LOGIC
  // ---------------------------------------------------------------------------

  // NEW: Fetch user by email query if they didn't use username
  Future<Map<String, dynamic>?> _fetchUserByEmail(String email) async {
    final url = Uri.parse('https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents:runQuery');
    
    try {
      final response = await http.post(
        url,
        body: jsonEncode({
          "structuredQuery": {
            "from": [{"collectionId": "users"}],
            "where": {
              "fieldFilter": {
                "field": {"fieldPath": "personal_email"},
                "op": "EQUAL",
                "value": {"stringValue": email}
              }
            },
            "limit": 1
          }
        }),
      );

      if (response.statusCode != 200) return null;

      final List data = jsonDecode(response.body);
      
      // If found, data[0] will have the "document" field.
      // If NOT found, data[0] might exist but strictly contain a "readTime" and no "document".
      if (data.isNotEmpty && data[0]['document'] != null) {
        return data[0]['document']; 
      }
      return null;
    } catch (e) {
      print("Query Error: $e");
      return null;
    }
  }

  Future<void> _handleUsernameLogin() async {
    if (_userController.text.isEmpty || _passController.text.isEmpty) {
      _showError("Please enter username/email and password");
      return;
    }

    setState(() => _isLoading = true);

    try {
      final input = _userController.text.trim();
      final password = _passController.text;

      Map<String, dynamic>? userData;
      String username = input; // Default assumption

      // 1. Check if input is an Email or Username
      if (input.contains('@')) {
        // --- EMAIL LOGIN PATH ---
        final doc = await _fetchUserByEmail(input);
        if (doc == null) throw "Incorrect password or username/email.";
        
        userData = doc;
        // Extract real username from document path ".../users/REAL_USERNAME"
        String path = doc['name']; 
        username = path.split('/').last; 
      } else {
        // --- USERNAME LOGIN PATH ---
        final url = Uri.parse(
          'https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents/users/$input'
        );
        final response = await http.get(url);

        if (response.statusCode == 404) throw "User not found.";
        if (response.statusCode != 200) throw "Server Error";
        
        userData = jsonDecode(response.body);
      }

      // 2. Extract Fields
      final fields = userData!['fields'];
      String storedHash = fields['password_hash']?['stringValue'] ?? "";
      String firstName = fields['first_name']?['stringValue'] ?? "";
      String lastName = fields['last_name']?['stringValue'] ?? "";
      int salary = int.tryParse(fields['salary']?['integerValue'] ?? '10000') ?? 10000;
      String email = fields['personal_email']?['stringValue'] ?? username;

      // 3. Verify Password
      bool verified = _verifyPassword(password, storedHash);

      if (verified) {
        String fullName = "$firstName $lastName";
        // Save to device (We save the REAL username so next auto-login is fast)
        await _saveLoginState('username', fullName, username);

        Map<String, dynamic> fakeGoogleData = {
          'name': fullName,
          'email': username, // Keep ID as username for consistency
          'id': username,
          'custom_salary': salary, 
        };

        if (!mounted) return;
        _navigateToHome(fakeGoogleData);
      } else {
        throw "Incorrect password or username/email.";
      }
    } catch (e) {
      _showError(e.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
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

      final checkUrl = Uri.parse(
        'https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents/users/$username'
      );
      
      final checkResponse = await http.get(checkUrl);
      if (checkResponse.statusCode == 200) {
        throw "Username '$username' is already taken.";
      }

      String hashedPassword = _hashPassword(password);

      final createUrl = Uri.parse(
        'https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents/users/$username'
      );

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

      if (createResponse.statusCode != 200) {
        throw "Failed to create account: ${createResponse.body}";
      }

      _showSuccess("Account created! Please login.");
      
      setState(() {
        _mode = LoginMode.username;
        _passController.clear();
        _userController.text = username;
      });

    } catch (e) {
      _showError(e.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleGoogleSignIn() async {
    setState(() => _isLoading = true);
    try {
      final credentials = await googleSignIn.signIn();
      if (credentials != null) {
        final authClient = await googleSignIn.authenticatedClient;
        if (authClient != null) {
          final userData = await _fetchGoogleUserProfile(authClient);
          
          await _saveLoginState('google', userData['name'], userData['email']);

          if (!mounted) return;
          _navigateToHome(userData);
        }
      }
    } catch (error) {
      _showError("Google Sign in failed: $error");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<Map<String, dynamic>> _fetchGoogleUserProfile(http.Client client) async {
    final response = await client.get(Uri.parse('https://www.googleapis.com/oauth2/v2/userinfo'));
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      throw Exception('Failed to load user profile');
    }
  }

  // --- NAVIGATION & UI HELPERS ---

  void _navigateToHome(Map<String, dynamic> userData) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) => MainPageController(userData: userData),
      ),
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
                errorBuilder: (context, error, stackTrace) => const Icon(Icons.school, size: 80),
              ),
              const SizedBox(height: 30),
              const Text("ISB Finance", style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
              const Text("Staff Loan Portal", style: TextStyle(fontSize: 16, color: Colors.grey)),
              const SizedBox(height: 40),

              if (_isLoading)
              // --- NEW CODE START ---
                Column(
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    TextButton.icon(
                      onPressed: () {
                        setState(() => _isLoading = false);
                      },
                      icon: const Icon(Icons.close, color: Colors.red),
                      label: const Text("Cancel Login", style: TextStyle(color: Colors.red)),
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
    return Column(
      children: [
        SizedBox(
          width: 280,
          height: 50,
          child: ElevatedButton.icon(
            onPressed: _handleGoogleSignIn,
            icon: Image.network('https://upload.wikimedia.org/wikipedia/commons/thumb/c/c1/Google_%22G%22_logo.svg/1200px-Google_%22G%22_logo.svg.png', height: 24),
            label: const Text("Sign in with Google", style: TextStyle(fontSize: 16, color: Colors.black87)),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: Colors.black,
              elevation: 3,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
            ),
          ),
        ),
        const SizedBox(height: 24),
        TextButton(
          onPressed: () => setState(() => _mode = LoginMode.username),
          child: const Text("Don't have a Google email?", style: TextStyle(color: Colors.blue, fontWeight: FontWeight.bold)),
        )
      ],
    );
  }

  Widget _buildUsernamePanel() {
    return Container(
      width: 350,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        children: [
          const Text("Staff Login", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 20),
          TextField(
            controller: _userController,
            // UPDATED LABEL
            decoration: const InputDecoration(labelText: "Username or Email", prefixIcon: Icon(Icons.person), border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          
          // --- REPLACE THE PASSWORD TEXTFIELD WITH THIS ---
          TextField(
            controller: _passController,
            obscureText: !_isPasswordVisible, // Toggle logic
            decoration: InputDecoration(
              labelText: "Password",
              prefixIcon: const Icon(Icons.lock),
              border: const OutlineInputBorder(),
              // Add the Eye Icon Button
              suffixIcon: IconButton(
                icon: Icon(
                  _isPasswordVisible ? Icons.visibility : Icons.visibility_off,
                  color: Colors.grey,
                ),
                onPressed: () {
                  setState(() {
                    _isPasswordVisible = !_isPasswordVisible;
                  });
                },
              ),
            ),
          ),
          // ------------------------------------------------
          
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _showForgotPasswordDialog,
              child: const Text("Forgot Password?", style: TextStyle(color: Colors.grey, fontSize: 12)),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            height: 45,
            child: ElevatedButton(
              onPressed: _handleUsernameLogin,
              style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
              child: const Text("Login", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton(
                onPressed: () => setState(() => _mode = LoginMode.google),
                child: const Text("Back", style: TextStyle(color: Colors.grey)),
              ),
              TextButton(
                onPressed: () {
                  _userController.clear();
                  _passController.clear();
                  _firstNameController.clear();
                  _lastNameController.clear();
                  _emailController.clear();
                  setState(() => _mode = LoginMode.signup);
                },
                child: const Text("Create Account", style: TextStyle(color: Colors.blue)),
              ),
            ],
          )
        ],
      ),
    );
  }

  Widget _buildSignUpPanel() {
    return Container(
      width: 350,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        children: [
          const Text("Create Account", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(child: TextField(controller: _firstNameController, decoration: const InputDecoration(labelText: "First Name", border: OutlineInputBorder()))),
              const SizedBox(width: 12),
              Expanded(child: TextField(controller: _lastNameController, decoration: const InputDecoration(labelText: "Last Name", border: OutlineInputBorder()))),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: "Personal Email (For Recovery)", prefixIcon: Icon(Icons.email), border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _userController,
            decoration: const InputDecoration(labelText: "Username", prefixIcon: Icon(Icons.person), border: OutlineInputBorder()),
          ),
          // ... inside _buildSignUpPanel ...

          const SizedBox(height: 16),
          
          // --- REPLACE THE PASSWORD TEXTFIELD WITH THIS ---
          TextField(
            controller: _passController,
            obscureText: !_isPasswordVisible,
            decoration: InputDecoration(
              labelText: "Password",
              prefixIcon: const Icon(Icons.lock),
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(
                  _isPasswordVisible ? Icons.visibility : Icons.visibility_off,
                  color: Colors.grey,
                ),
                onPressed: () {
                  setState(() {
                    _isPasswordVisible = !_isPasswordVisible;
                  });
                },
              ),
            ),
          ),
          // ------------------------------------------------

          const SizedBox(height: 24),
          // ... rest of the code
          SizedBox(
            width: double.infinity,
            height: 45,
            child: ElevatedButton(
              onPressed: _handleSignUp,
              style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
              child: const Text("Sign Up", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: () => setState(() => _mode = LoginMode.username),
            child: const Text("Back to Login", style: TextStyle(color: Colors.grey)),
          ),
        ],
      ),
    );
  }
}