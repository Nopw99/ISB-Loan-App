import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class Api {
  
  // --- 1. INTERNAL TOOLS ---

  // NEW HELPER: Ensures author_uid is present if a user is logged in
  static Map<String, dynamic> _injectAuthData(Map<String, dynamic> data) {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      // Only set if the key doesn't exist or is null
      data['author_uid'] ??= user.uid;
      
      // Optional: Also track email if not present
      if (user.email != null) {
        data['email'] ??= user.email;
      }
    }
    return data;
  }

  static String _getPathFromUrl(Uri url) {
    String fullPath = Uri.decodeFull(url.path); 
    if (fullPath.endsWith(':runQuery')) return ":runQuery";

    int docIndex = fullPath.indexOf('/documents/');
    if (docIndex == -1) {
      if (fullPath.endsWith('/documents')) return ""; 
      return "";
    }

    String cleanPath = fullPath.substring(docIndex + 11);
    return cleanPath.endsWith('/') ? cleanPath.substring(0, cleanPath.length - 1) : cleanPath;
  }

  static Map<String, dynamic> _simplifyRestBody(String jsonBody) {
    if (jsonBody.isEmpty) return {};
    try {
      final Map<String, dynamic> raw = jsonDecode(jsonBody);
      if (!raw.containsKey('fields')) return raw;
      
      final Map<String, dynamic> fields = raw['fields'];
      final Map<String, dynamic> cleanData = {};

      fields.forEach((key, valueMap) {
        if (valueMap is Map) {
          if (valueMap.containsKey('stringValue')) cleanData[key] = valueMap['stringValue'];
          else if (valueMap.containsKey('integerValue')) cleanData[key] = int.tryParse(valueMap['integerValue'].toString()) ?? 0;
          else if (valueMap.containsKey('doubleValue')) cleanData[key] = valueMap['doubleValue'];
          else if (valueMap.containsKey('booleanValue')) cleanData[key] = valueMap['booleanValue'];
          else if (valueMap.containsKey('timestampValue')) cleanData[key] = valueMap['timestampValue'];
        }
      });
      return cleanData;
    } catch (e) {
      return {};
    }
  }

  static Map<String, dynamic> _encodeToRest(Map<String, dynamic> data) {
    Map<String, dynamic> fields = {};
    data.forEach((key, value) {
      if (value is String) fields[key] = {'stringValue': value};
      else if (value is int) fields[key] = {'integerValue': value.toString()};
      else if (value is double) fields[key] = {'doubleValue': value};
      else if (value is bool) fields[key] = {'booleanValue': value};
      else if (value is Timestamp) fields[key] = {'timestampValue': value.toDate().toIso8601String()};
    });
    return fields;
  }

  // --- 2. PUBLIC METHODS ---

  static Future<http.Response> get(Uri url) async {
  final user = FirebaseAuth.instance.currentUser;
  
  // Define who the admin is
  bool isAdmin = user?.email == "20981@students.isb.ac.th";

  try {
    String path = _getPathFromUrl(url);
    if (path == "") return http.Response('{"documents": []}', 200);

    bool isCollection = path.split('/').length % 2 != 0;

    if (isCollection) {
      Query query = FirebaseFirestore.instance.collection(path);
      
      // LOGIC CHANGE: 
      // Only apply the filter if the user is NOT the admin.
      if (path != 'users' && user != null && !isAdmin) {
        query = query.where('author_uid', isEqualTo: user.uid);
      }

        QuerySnapshot snapshot = await query.get();
        List<Map<String, dynamic>> documents = snapshot.docs.map((doc) {
          return {
            "name": "projects/mock/databases/(default)/documents/$path/${doc.id}",
            "fields": _encodeToRest(doc.data() as Map<String, dynamic>)
          };
        }).toList();

        return http.Response(jsonEncode({"documents": documents}), 200);
      } else {
        DocumentSnapshot doc = await FirebaseFirestore.instance.doc(path).get();
        if (!doc.exists) return http.Response('{}', 404);
        return http.Response(jsonEncode({
          "name": "projects/mock/databases/(default)/documents/$path/${doc.id}",
          "fields": _encodeToRest(doc.data() as Map<String, dynamic>)
        }), 200);
      }
    } catch (e) {
      return http.Response('{"documents": []}', 200); 
    }
  }

  static Future<http.Response> post(Uri url, {required String body}) async {
    final user = FirebaseAuth.instance.currentUser;
    try {
      String path = _getPathFromUrl(url);

      if (path == ":runQuery") {
        Map<String, dynamic> queryBody = jsonDecode(body);
        String collectionId = queryBody['structuredQuery']['from'][0]['collectionId'] ?? "";
        if (collectionId.isEmpty) return http.Response('[]', 200);

        Query query = FirebaseFirestore.instance.collection(collectionId);
        if (user != null) query = query.where('author_uid', isEqualTo: user.uid);

        QuerySnapshot snapshot = await query.get();
        List<Map<String, dynamic>> results = snapshot.docs.map((doc) {
          return {
            "document": {
              "name": "projects/mock/databases/(default)/documents/$collectionId/${doc.id}",
              "fields": _encodeToRest(doc.data() as Map<String, dynamic>),
            },
            "readTime": DateTime.now().toIso8601String(),
          };
        }).toList();
        return http.Response(jsonEncode(results), 200);
      }

      // --- CREATE LOGIC ---
      Map<String, dynamic> data = _simplifyRestBody(body);
      data = _injectAuthData(data); // <--- INJECTED HERE

      if (!data.containsKey('timestamp')) {
        data['timestamp'] = FieldValue.serverTimestamp();
      }

      DocumentReference ref = await FirebaseFirestore.instance.collection(path).add(data);
      return http.Response('{"name": "${ref.path}"}', 200);
    } catch (e) {
      return http.Response('{"error": "$e"}', 500);
    }
  }

  static Future<http.Response> patch(Uri url, {required String body}) async {
    try {
      String path = _getPathFromUrl(url);
      Map<String, dynamic> data = _simplifyRestBody(body);
      
      data = _injectAuthData(data); // <--- INJECTED HERE

      await FirebaseFirestore.instance.doc(path).set(data, SetOptions(merge: true));
      return http.Response('{}', 200);
    } catch (e) {
      return http.Response('{"error": "$e"}', 500);
    }
  }

  static Future<http.Response> delete(Uri url) async {
    try {
      String path = _getPathFromUrl(url);
      await FirebaseFirestore.instance.doc(path).delete();
      return http.Response('{}', 200);
    } catch (e) {
      return http.Response('{"error": "$e"}', 500);
    }
  }
}