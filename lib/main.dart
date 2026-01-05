import 'package:finance_app/secrets.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http; 
import 'dart:convert';
import 'package:url_launcher/url_launcher.dart'; 
import 'package:shared_preferences/shared_preferences.dart'; 
import 'auth_config.dart'; 

// Import all your pages
import 'login_page.dart';
import 'user_homepage.dart';
import 'loan_application_page.dart';
import 'admin_homepage.dart';

// --- GLOBAL THEME NOTIFIER ---
// This allows us to toggle the theme from anywhere in the app
final ValueNotifier<ThemeMode> themeModeNotifier = ValueNotifier(ThemeMode.light);

const BoxDecoration kAppBackground = BoxDecoration(
  gradient: LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFFFDFBFB), Color(0xFFEBEDEE)], 
  ),
);

// Dark Mode Background
const BoxDecoration kAppBackgroundDark = BoxDecoration(
  gradient: LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF121212), Color(0xFF1E1E1E)], 
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
    // Wrap MaterialApp in ValueListenableBuilder to listen for theme changes
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, currentMode, _) {
        return MaterialApp(
          title: 'ISB Finance',
          debugShowCheckedModeBanner: false,
          themeMode: currentMode, // <--- Dynamic Theme Mode
          
          // --- LIGHT THEME ---
          theme: ThemeData(
            useMaterial3: true,
            primarySwatch: Colors.blue,
            scaffoldBackgroundColor: Colors.grey[50],
            canvasColor: Colors.white,
            brightness: Brightness.light,
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

          // --- DARK THEME ---
          darkTheme: ThemeData(
            useMaterial3: true,
            primarySwatch: Colors.blue,
            scaffoldBackgroundColor: const Color(0xFF121212),
            canvasColor: const Color(0xFF1E1E1E),
            brightness: Brightness.dark,
            cardColor: const Color(0xFF1E1E1E),
            appBarTheme: const AppBarTheme(
              backgroundColor: Colors.transparent,
              elevation: 0,
              iconTheme: IconThemeData(color: Colors.white),
              titleTextStyle: TextStyle(
                color: Colors.white, 
                fontSize: 20, 
                fontWeight: FontWeight.bold
              ),
            ),
          ),

          home: const SplashScreen(),
        );
      },
    );
  }
}

// --- SPLASH SCREEN ---
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
    await Future.delayed(const Duration(seconds: 1));

    final prefs = await SharedPreferences.getInstance();
    final bool isLoggedIn = prefs.getBool('isLoggedIn') ?? false;

    if (isLoggedIn && mounted) {
      String name = prefs.getString('userName') ?? "User";
      String email = prefs.getString('userEmail') ?? "";
      
      Map<String, dynamic> savedData = {
        'name': name,
        'email': email,
      };

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
    // Use theme-aware background color
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
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

// --- CONTROLLER & PAGES ---
class MainPageController extends StatefulWidget {
  final Map<String, dynamic> userData;

  const MainPageController({super.key, required this.userData});

  @override
  State<MainPageController> createState() => _MainPageControllerState();
}

class _MainPageControllerState extends State<MainPageController> {
  bool _showLoanApplication = false;
  double _currentSalary = 0; 

  Future<void> _handleLogout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    await googleSignIn.signOut();
    
    // Reset theme to light on logout
    themeModeNotifier.value = ThemeMode.light;

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
        userName: name, 
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