// lib/auth_config.dart
import 'package:google_sign_in_all_platforms/google_sign_in_all_platforms.dart';
import 'secrets.dart';

// GLOBAL INSTANCE - Created only once!
final GoogleSignIn googleSignIn = GoogleSignIn(
  params: const GoogleSignInParams(
    // PASTE YOUR CLIENT ID AND SECRET HERE AGAIN
    clientId: googleClientId,
    clientSecret: googleClientSecret, 
    redirectPort: 8000, 
    scopes: ['email', 'profile', 'openid'],
    timeout: Duration(minutes: 2), 
  ),
);