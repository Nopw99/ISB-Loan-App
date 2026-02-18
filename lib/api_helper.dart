import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class Api {
  
  // --- 1. INTERNAL TOOLS ---

  static String _getPathFromUrl(Uri url) {
    String fullPath = Uri.decodeFull(url.path); 
    
    // Handle :runQuery specially (it doesn't have a trailing slash)
    if (fullPath.endsWith(':runQuery')) {
      return ":runQuery";
    }

    int docIndex = fullPath.indexOf('/documents/');
    if (docIndex == -1) {
      // Fallback: Check if it ends in /documents (root collection list)
      if (fullPath.endsWith('/documents')) return ""; 
      print("⚠️ API Helper: Could not find '/documents/' in URL: $fullPath");
      return "";
    }

    String cleanPath = fullPath.substring(docIndex + 11);
    if (cleanPath.endsWith('/')) {
      cleanPath = cleanPath.substring(0, cleanPath.length - 1);
    }
    return cleanPath;
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

  // GET
  static Future<http.Response> get(Uri url) async {
    // Debug Auth State
    final user = FirebaseAuth.instance.currentUser;
    // print("🔍 API GET: ${url.path} | User: ${user?.uid ?? 'Unauthenticated'}");

    if (url.toString().contains('firebaseio.com') || url.path.endsWith('.json')) {
       final token = user != null ? await user.getIdToken() : null;
       final Map<String, String> headers = token != null 
           ? {'Authorization': 'Bearer $token'} 
           : <String, String>{}; 
       return http.get(url, headers: headers);
    }

    try {
      String path = _getPathFromUrl(url);
      if (path == "") return http.Response('{"documents": []}', 200);

      bool isCollection = path.split('/').length % 2 != 0;

      if (isCollection) {
        // Fetch Collection: Automatically filter by user if it's a private collection
        Query query = FirebaseFirestore.instance.collection(path);
        
        // Security: If not 'users', only show my own data
        if (path != 'users' && user != null) {
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

        final responseBody = jsonEncode({
          "name": "projects/mock/databases/(default)/documents/$path/${doc.id}",
          "fields": _encodeToRest(doc.data() as Map<String, dynamic>)
        });
        return http.Response(responseBody, 200);
      }
    } catch (e) {
      print("❌ SDK Get Error: $e");
      return http.Response('{"documents": []}', 200); 
    }
  }

  // POST (Create OR Query)
  static Future<http.Response> post(Uri url, {required String body}) async {
    final user = FirebaseAuth.instance.currentUser;
    // print("🔍 API POST: ${url.path} | User: ${user?.uid ?? 'Unauthenticated'}");

    try {
      String path = _getPathFromUrl(url);

      // --- HANDLE REST QUERIES (:runQuery) ---
      if (path == ":runQuery") {
        // 1. Parse the request to find which collection we are querying
        Map<String, dynamic> queryBody = jsonDecode(body);
        String collectionId = "";
        
        try {
          // Navigate deep JSON structure: structuredQuery -> from -> [0] -> collectionId
          collectionId = queryBody['structuredQuery']['from'][0]['collectionId'];
        } catch (e) {
          print("⚠️ Could not parse collectionId from runQuery. Defaulting to empty.");
          return http.Response('[]', 200);
        }

        if (collectionId.isEmpty) return http.Response('[]', 200);

        // 2. Execute SDK Query
        // For safety, we just fetch ALL the user's docs in this collection 
        // and let the UI handle the rest. This ignores complex filters but works for basic apps.
        Query query = FirebaseFirestore.instance.collection(collectionId);
        
        if (user != null) {
          query = query.where('author_uid', isEqualTo: user.uid);
        }

        QuerySnapshot snapshot = await query.get();

        // 3. Format as runQuery response (List of objects with 'document' and 'readTime')
        List<Map<String, dynamic>> results = snapshot.docs.map((doc) {
          return {
            "document": {
              "name": "projects/mock/databases/(default)/documents/$collectionId/${doc.id}",
              "fields": _encodeToRest(doc.data() as Map<String, dynamic>),
              "createTime": DateTime.now().toIso8601String(),
              "updateTime": DateTime.now().toIso8601String(),
            },
            "readTime": DateTime.now().toIso8601String(),
          };
        }).toList();

        return http.Response(jsonEncode(results), 200);
      }

      // --- HANDLE STANDARD CREATE ---
      if (path.isEmpty) return http.Response('{"error": "Invalid Path"}', 400);

      Map<String, dynamic> data = _simplifyRestBody(body);
      
      if (user != null) {
        data['author_uid'] = user.uid;
        if (user.email != null) data['email'] = user.email;
      }

      if (!data.containsKey('timestamp')) {
        data['timestamp'] = FieldValue.serverTimestamp();
      }

      DocumentReference ref = await FirebaseFirestore.instance.collection(path).add(data);
      return http.Response('{"name": "${ref.path}"}', 200);

    } catch (e) {
      print("❌ SDK Post Error: $e");
      return http.Response('{"error": "$e"}', 500);
    }
  }

  // PATCH (Update)
  static Future<http.Response> patch(Uri url, {required String body}) async {
    try {
      String path = _getPathFromUrl(url);
      Map<String, dynamic> data = _simplifyRestBody(body);
      await FirebaseFirestore.instance.doc(path).set(data, SetOptions(merge: true));
      return http.Response('{}', 200);
    } catch (e) {
      print("❌ SDK Patch Error: $e");
      return http.Response('{"error": "$e"}', 500);
    }
  }

  // DELETE
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