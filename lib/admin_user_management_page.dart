import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:intl/intl.dart'; // <--- IMPORT THIS
import 'secrets.dart';
import 'admin_user_details_page.dart'; // <--- IMPORT THE NEW PAGE

class AdminUserManagementPage extends StatefulWidget {
  const AdminUserManagementPage({super.key});

  @override
  State<AdminUserManagementPage> createState() => _AdminUserManagementPageState();
}

class _AdminUserManagementPageState extends State<AdminUserManagementPage> {
  List<dynamic> _users = [];
  bool _isLoading = true;
  String _searchQuery = "";
  final _formatter = NumberFormat("#,##0"); // <--- Number formatter

  @override
  void initState() {
    super.initState();
    _fetchUsers();
  }

  Future<void> _fetchUsers() async {
    setState(() => _isLoading = true);
    final url = Uri.parse(
        'https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents/users');

    try {
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _users = data['documents'] ?? [];
          _isLoading = false;
        });
      } else {
        throw "Failed to load users: ${response.statusCode}";
      }
    } catch (e) {
      print("Error fetching users: $e");
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // --- 2. UPDATE SALARY ---
  Future<void> _updateSalary(String docId, String currentSalary) async {
    // Format initial text with commas
    final initialVal = _formatter.format(int.tryParse(currentSalary.replaceAll(',', '')) ?? 0);
    TextEditingController salaryCtrl = TextEditingController(text: initialVal);
    
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Update Base Salary"),
        content: TextField(
          controller: salaryCtrl,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly, 
            CurrencyInputFormatter(), 
          ],
          decoration: const InputDecoration(labelText: "New Salary (THB)", border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              String newSalaryClean = salaryCtrl.text.replaceAll(',', '');
              
              if (newSalaryClean.isEmpty) return;

              bool success = await _performPatch(docId, "salary", {"integerValue": newSalaryClean});
              
              if (success) {
                setState(() {
                  final index = _users.indexWhere((u) => u['name'] == docId);
                  if (index != -1) {
                    if (_users[index]['fields']['salary'] == null) {
                       _users[index]['fields']['salary'] = {};
                    }
                    _users[index]['fields']['salary']['integerValue'] = newSalaryClean;
                  }
                });
              }
            },
            child: const Text("Update"),
          )
        ],
      ),
    );
  }

  // --- 3. TOGGLE DISABLE ACCOUNT ---
  Future<void> _toggleDisable(String docId, bool currentStatus) async {
    bool newStatus = !currentStatus;
    
    if (newStatus) { 
      bool? confirm = await showDialog(
        context: context, 
        builder: (c) => AlertDialog(
          title: const Text("Disable Account?"),
          content: const Text("This user will no longer be able to apply for loans."),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text("Cancel")),
            TextButton(onPressed: () => Navigator.pop(c, true), child: const Text("Disable", style: TextStyle(color: Colors.red))),
          ],
        )
      );
      if (confirm != true) return; 
    }

    setState(() {
      final index = _users.indexWhere((u) => u['name'] == docId);
      if (index != -1) {
         if (_users[index]['fields']['is_disabled'] == null) {
            _users[index]['fields']['is_disabled'] = {};
         }
        _users[index]['fields']['is_disabled']['booleanValue'] = newStatus;
      }
    });

    bool success = await _performPatch(docId, "is_disabled", {"booleanValue": newStatus});

    if (!success) {
      setState(() {
        final index = _users.indexWhere((u) => u['name'] == docId);
        if (index != -1) {
          _users[index]['fields']['is_disabled']['booleanValue'] = currentStatus; 
        }
      });
    }
  }

  Future<bool> _performPatch(String docId, String fieldName, Map<String, dynamic> value) async {
    String cleanId = docId.split('/').last; 
    final url = Uri.parse(
        'https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents/users/$cleanId?updateMask.fieldPaths=$fieldName');

    try {
      final response = await http.patch(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          "fields": {
            fieldName: value
          }
        }),
      );

      if (response.statusCode == 200) {
        return true; 
      } else {
        throw "Update failed: ${response.body}";
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e"), backgroundColor: Colors.red));
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final filteredUsers = _users.where((user) {
      final fields = user['fields'];
      String name = (fields['first_name']?['stringValue'] ?? "") + " " + (fields['last_name']?['stringValue'] ?? "");
      String username = fields['username']?['stringValue'] ?? "";
      String email = fields['personal_email']?['stringValue'] ?? "";
      String q = _searchQuery.toLowerCase();
      return name.toLowerCase().contains(q) || username.toLowerCase().contains(q) || email.toLowerCase().contains(q);
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          decoration: const InputDecoration(
            hintText: "Search Staff...",
            border: InputBorder.none,
            hintStyle: TextStyle(color: Colors.grey),
          ),
          style: const TextStyle(color: Colors.black),
          onChanged: (val) => setState(() => _searchQuery = val),
        ),
        backgroundColor: Colors.white,
        elevation: 1,
        iconTheme: const IconThemeData(color: Colors.black),
      ),
      body: _isLoading 
        ? const Center(child: CircularProgressIndicator()) 
        : ListView.builder(
            itemCount: filteredUsers.length,
            padding: const EdgeInsets.all(16),
            itemBuilder: (context, index) {
              final user = filteredUsers[index];
              final fields = user['fields'];
              final docId = user['name']; 

              String firstName = fields['first_name']?['stringValue'] ?? "Unknown";
              String lastName = fields['last_name']?['stringValue'] ?? "";
              String email = fields['personal_email']?['stringValue'] ?? "No Email";
              String salary = fields['salary']?['integerValue'] ?? "0";
              bool isDisabled = fields['is_disabled']?['booleanValue'] ?? false;

              // --- FORMAT SALARY FOR DISPLAY ---
              String displaySalary = _formatter.format(int.tryParse(salary) ?? 0);

              return Card(
                elevation: 2,
                color: isDisabled ? Colors.grey[200] : Colors.white,
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  // --- CLICK TO VIEW DETAILS ---
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => AdminUserDetailsPage(userData: user),
                      ),
                    );
                  },
                  leading: CircleAvatar(
                    backgroundColor: isDisabled ? Colors.grey : Colors.blue,
                    child: Icon(isDisabled ? Icons.block : Icons.person, color: Colors.white),
                  ),
                  title: Text("$firstName $lastName", style: TextStyle(fontWeight: FontWeight.bold, color: isDisabled ? Colors.grey : Colors.black)),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(email),
                      const SizedBox(height: 4),
                      // --- UPDATED DISPLAY WITH COMMAS ---
                      Text("Salary: $displaySalary THB", style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit, color: Colors.blue),
                        tooltip: "Edit Salary",
                        onPressed: () => _updateSalary(docId, salary),
                      ),
                      
                      Tooltip(
                        message: isDisabled 
                            ? "Enable ability to apply for loans" 
                            : "Disable ability to apply for loans", 
                        child: Switch(
                          value: !isDisabled, 
                          activeColor: Colors.green,
                          inactiveTrackColor: Colors.red[100],
                          inactiveThumbColor: Colors.red,
                          onChanged: (val) {
                            _toggleDisable(docId, isDisabled); 
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
    );
  }
}

class CurrencyInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    if (newValue.selection.baseOffset == 0) return newValue;
    String cleanText = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (cleanText.isEmpty) return newValue;
    double value = double.parse(cleanText);
    final formatter = NumberFormat("#,###");
    String newText = formatter.format(value);
    return newValue.copyWith(
      text: newText,
      selection: TextSelection.collapsed(offset: newText.length),
    );
  }
}