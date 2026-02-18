import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart'; 
import 'package:shared_preferences/shared_preferences.dart'; 
import 'package:flutter_svg/flutter_svg.dart';

// Your Helper & Config Imports
import 'package:finance_app/secrets.dart';
import 'api_helper.dart'; 
import 'auth_config.dart'; 

// Page Imports
import 'login_page.dart';
import 'user_homepage.dart';
import 'loan_application_page.dart';
import 'admin_homepage.dart';

// --- GLOBAL CONSTANTS ---
const BoxDecoration kAppBackground = BoxDecoration(
  gradient: LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFFFDFBFB), Color(0xFFEBEDEE)], 
  ),
);

const BoxDecoration kAppBackgroundDark = BoxDecoration(
  gradient: LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF121212), Color(0xFF1E1E1E)], 
  ),
);

// --- GLOBAL THEME NOTIFIER ---
final ValueNotifier<ThemeMode> themeModeNotifier = ValueNotifier(ThemeMode.light);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e) {
    debugPrint("Firebase Initialization Error: $e");
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, currentMode, _) {
        return MaterialApp(
          title: 'ISB Finance',
          debugShowCheckedModeBanner: false,
          themeMode: currentMode,
          theme: ThemeData(
            useMaterial3: true,
            colorSchemeSeed: Colors.blue,
            scaffoldBackgroundColor: Colors.grey[50],
            brightness: Brightness.light,
            appBarTheme: const AppBarTheme(
              backgroundColor: Colors.transparent,
              elevation: 0,
              titleTextStyle: TextStyle(color: Colors.black87, fontSize: 20, fontWeight: FontWeight.bold),
            ),
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            colorSchemeSeed: Colors.blue,
            scaffoldBackgroundColor: const Color(0xFF121212),
            brightness: Brightness.dark,
            appBarTheme: const AppBarTheme(
              backgroundColor: Colors.transparent,
              elevation: 0,
              titleTextStyle: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
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
    await Future.delayed(const Duration(seconds: 2));

    final prefs = await SharedPreferences.getInstance();
    final bool isLoggedIn = prefs.getBool('isLoggedIn') ?? false;

    if (isLoggedIn && mounted) {
      String name = prefs.getString('userName') ?? "User";
      String email = prefs.getString('userEmail') ?? "";
      
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) => MainPageController(userData: {'name': name, 'email': email})
        ),
      );
    } else {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (context) => const LoginPage()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SvgPicture.asset('assets/isb_logo.svg', height: 100),
            const SizedBox(height: 30),
            const CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }
}

// --- MAIN PAGE CONTROLLER ---
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
    
    themeModeNotifier.value = ThemeMode.light;

    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (context) => const LoginPage()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    String email = widget.userData['email'] ?? "Unknown";
    String name = widget.userData['name'] ?? "User";

    if (email.trim().toLowerCase() == adminEmail.trim().toLowerCase()) {
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