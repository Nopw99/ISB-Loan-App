import 'package:finance_app/secrets.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http; 
import 'dart:convert';
import 'package:url_launcher/url_launcher.dart'; 
import 'package:shared_preferences/shared_preferences.dart'; // NEW IMPORT
import 'auth_config.dart'; 

// Import all your pages
import 'login_page.dart';
import 'user_homepage.dart';
import 'loan_application_page.dart';
import 'admin_homepage.dart';

const BoxDecoration kAppBackground = BoxDecoration(
  gradient: LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFFFDFBFB), Color(0xFFEBEDEE)], 
  ),
);

void main() async{
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ISB Finance',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        primarySwatch: Colors.blue,
        scaffoldBackgroundColor: Colors.grey[50],
        canvasColor: Colors.white,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          iconTheme: IconThemeData(color: Colors.black87),
          titleTextStyle: TextStyle(
            color: Colors.black87, 
            fontSize: 20, 
            fontWeight: FontWeight.bold
          ),
        ),
      ),
      // CHANGE: Point to a Splash Screen instead of Login Page directly
      home: const SplashScreen(),
    );
  }
}

// --- NEW SPLASH SCREEN (Checks for Auto-Login) ---
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _checkLoginStatus();
  }

  Future<void> _checkLoginStatus() async {
    // Artificial delay to show logo
    await Future.delayed(const Duration(seconds: 1));

    final prefs = await SharedPreferences.getInstance();
    final bool isLoggedIn = prefs.getBool('isLoggedIn') ?? false;

    if (isLoggedIn && mounted) {
      // 1. Retrieve saved user data from device
      String name = prefs.getString('userName') ?? "User";
      String email = prefs.getString('userEmail') ?? "";
      
      // 2. Construct the user data map
      Map<String, dynamic> savedData = {
        'name': name,
        'email': email,
      };

      // (Removed the googleSignIn.signInSilently() call to fix the error)
      // We trust the local storage for this session.

      // 3. Go to Home
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (context) => MainPageController(userData: savedData)),
      );
    } else {
      _goToLogin();
    }
  }

  void _goToLogin() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (context) => const LoginPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.network(
              'https://www.isb.ac.th/wp-content/uploads/2019/08/ISB-Logo-Color.png',
              height: 120,
              errorBuilder: (context, error, stackTrace) => const Icon(Icons.school, size: 80),
            ),
            const SizedBox(height: 20),
            const CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }
}

// --- CONTROLLER & PAGES (Keep these same as before) ---
class MainPageController extends StatefulWidget {
  final Map<String, dynamic> userData;

  const MainPageController({super.key, required this.userData});

  @override
  State<MainPageController> createState() => _MainPageControllerState();
}

class _MainPageControllerState extends State<MainPageController> {
  bool _showLoanApplication = false;
  double _currentSalary = 0; 

  @override
  void initState() {
    super.initState();
  }

  bool _isUpdateAvailable(String current, String latest) {
    List<int> currParts = current.split('.').map(int.parse).toList();
    List<int> latParts = latest.split('.').map(int.parse).toList();

    for (int i = 0; i < latParts.length; i++) {
      if (i >= currParts.length) return true; 
      if (latParts[i] > currParts[i]) return true;
      if (latParts[i] < currParts[i]) return false;
    }
    return false; 
  }

  void _showUpdateDialog(String newVersion, String url) {
    showDialog(
      context: context,
      barrierDismissible: false, 
      builder: (context) => AlertDialog(
        title: const Text("New Update Available!"),
        content: Text("Version $newVersion is now available.\nPlease download the latest version to continue."),
        actions: [
          ElevatedButton(
            onPressed: () async {
              final uri = Uri.parse(url);
              if (await canLaunchUrl(uri)) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              } else {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Could not open link")));
              }
            },
            child: const Text("Download Update"),
          ),
        ],
      ),
    );
  }

  Future<void> _handleLogout() async {
    // 1. Clear Local Storage
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();

    // 2. Sign out of Google
    await googleSignIn.signOut();
    
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (context) => const LoginPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    String email = widget.userData['email'] ?? "Unknown";
    String name = widget.userData['name'] ?? "User";

    if (email.trim() == adminEmail) {
      return AdminHomepage(
        adminName: name, 
        onLogoutTap: _handleLogout,
      );
    }

    if (_showLoanApplication) {
      return LoanApplicationPage(
        initialSalary: _currentSalary,
        userEmail: email, 
        onBackTap: () => setState(() => _showLoanApplication = false),
      );
    } else {
      return UserHomepage(
        userEmail: email,
        userName: name, 
        onApplyTap: (salary) => setState(() {
          _currentSalary = salary;
          _showLoanApplication = true;
        }),
        onLogoutTap: _handleLogout,
      );
    }
  }
}