import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:intl/intl.dart';
import 'secrets.dart'; 
import 'loan_details_page.dart'; 

class AdminUserDetailsPage extends StatefulWidget {
  final Map<String, dynamic> userData; 

  const AdminUserDetailsPage({super.key, required this.userData});

  @override
  State<AdminUserDetailsPage> createState() => _AdminUserDetailsPageState();
}

class _AdminUserDetailsPageState extends State<AdminUserDetailsPage> {
  bool _isLoading = true;
  
  // --- NEW: User Status State ---
  late bool _isUserDisabled;
  late String _docId;
  // ------------------------------

  int _totalLoans = 0;
  int _approvedLoans = 0;
  int _rejectedLoans = 0;
  List<dynamic> _ongoingLoans = [];
  final _formatter = NumberFormat("#,##0");

  @override
  void initState() {
    super.initState();
    // Initialize status from passed data
    _isUserDisabled = widget.userData['fields']['is_disabled']?['booleanValue'] ?? false;
    _docId = widget.userData['name'].toString().split('/').last; // Extract ID for updates
    
    _fetchUserHistory();
  }

  // --- NEW: TOGGLE DISABLE LOGIC ---
  Future<void> _toggleUserDisable(bool currentStatus) async {
    bool newStatus = !currentStatus;
    
    // 1. Confirm Dialog
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

    // 2. Optimistic Update
    setState(() => _isUserDisabled = newStatus);

    // 3. API Call
    final url = Uri.parse(
        'https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents/users/$_docId?updateMask.fieldPaths=is_disabled');

    try {
      final response = await http.patch(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          "fields": {
            "is_disabled": {"booleanValue": newStatus}
          }
        }),
      );

      if (response.statusCode != 200) {
        throw "Update failed";
      }

    } catch (e) {
      // 4. Rollback on Error
      setState(() => _isUserDisabled = currentStatus);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e"), backgroundColor: Colors.red));
    }
  }
  // ---------------------------------

  Future<void> _fetchUserHistory() async {
    final fields = widget.userData['fields'];
    final email = fields['personal_email']?['stringValue'] ?? "";

    if (email.isEmpty) {
      setState(() => _isLoading = false);
      return;
    }

    final url = Uri.parse('https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents:runQuery');
    
    try {
      final response = await http.post(
        url,
        body: jsonEncode({
          "structuredQuery": {
            "from": [{"collectionId": "loan_applications"}],
            "where": {
              "fieldFilter": {
                "field": {"fieldPath": "email"},
                "op": "EQUAL",
                "value": {"stringValue": email}
              }
            }
          }
        }),
      );

      if (response.statusCode == 200) {
        final List data = jsonDecode(response.body);
        
        int total = 0;
        int approved = 0;
        int rejected = 0;
        List<dynamic> ongoing = [];

        for (var item in data) {
          if (item['document'] == null) continue;
          
          final doc = item['document'];
          final loanFields = doc['fields'];
          final status = (loanFields['status']?['stringValue'] ?? "").toLowerCase();

          total++;
          
          if (status == 'approved') {
            approved++;
          } else if (status == 'rejected') {
            rejected++;
          } else if (status == 'pending') {
            ongoing.add(doc);
          }
        }

        if (mounted) {
          setState(() {
            _totalLoans = total;
            _approvedLoans = approved;
            _rejectedLoans = rejected;
            _ongoingLoans = ongoing;
            _isLoading = false;
          });
        }
      } else {
        throw "Error fetching history";
      }
    } catch (e) {
      print("History Error: $e");
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fields = widget.userData['fields'];
    String firstName = fields['first_name']?['stringValue'] ?? "Unknown";
    String lastName = fields['last_name']?['stringValue'] ?? "";
    String email = fields['personal_email']?['stringValue'] ?? "No Email";
    
    String rawSalary = fields['salary']?['integerValue'] ?? "0";
    String formattedSalary = _formatter.format(int.tryParse(rawSalary) ?? 0);

    return Scaffold(
      appBar: AppBar(
        title: const Text("User Details", style: TextStyle(color: Colors.black)),
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.black),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // --- PROFILE HEADER ---
            Center(
              child: Column(
                children: [
                  CircleAvatar(
                    radius: 40,
                    // Change color if disabled to give visual feedback
                    backgroundColor: _isUserDisabled ? Colors.grey : Colors.blue[100],
                    child: _isUserDisabled 
                      ? const Icon(Icons.block, size: 40, color: Colors.white)
                      : Text(
                          firstName.isNotEmpty ? firstName[0].toUpperCase() : "?",
                          style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.blue),
                        ),
                  ),
                  const SizedBox(height: 16),
                  Text("$firstName $lastName", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: _isUserDisabled ? Colors.grey : Colors.black)),
                  Text(email, style: const TextStyle(color: Colors.grey, fontSize: 16)),
                  const SizedBox(height: 12),
                  
                  // --- SALARY BADGE ---
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(color: Colors.green[50], borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.green.withOpacity(0.5))),
                    child: Text("Salary: $formattedSalary THB", style: TextStyle(color: Colors.green[800], fontWeight: FontWeight.bold)),
                  ),

                  const SizedBox(height: 16),

                  // --- NEW: DISABLE SWITCH ---
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text("Active Status: ", style: TextStyle(color: Colors.grey[700], fontWeight: FontWeight.bold)),
                      Tooltip(
                        message: _isUserDisabled ? "Enable ability to apply for loans" 
                            : "Disable ability to apply for loans", 
                        child: Switch(
                          value: !_isUserDisabled, // Switch is ON if User is Active
                          activeColor: Colors.green,
                          inactiveTrackColor: Colors.red[100],
                          inactiveThumbColor: Colors.red,
                          onChanged: (val) {
                            // If val is true (switch on), we want to ENABLE (isUserDisabled = false)
                            // If val is false (switch off), we want to DISABLE (isUserDisabled = true)
                            _toggleUserDisable(_isUserDisabled);
                          },
                        ),
                      ),
                      Text(_isUserDisabled ? "Disabled" : "Active", 
                        style: TextStyle(
                          color: _isUserDisabled ? Colors.red : Colors.green, 
                          fontWeight: FontWeight.bold
                        )
                      ),
                    ],
                  ),
                  // --------------------------
                ],
              ),
            ),
            
            const SizedBox(height: 32),
            
            // --- STATS ROW ---
            const Text("Statistics", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            if (_isLoading) 
              const Center(child: CircularProgressIndicator())
            else
              Row(
                children: [
                  _buildStatCard("Total", _totalLoans.toString(), Colors.blue),
                  const SizedBox(width: 12),
                  _buildStatCard("Approved", _approvedLoans.toString(), Colors.green),
                  const SizedBox(width: 12),
                  _buildStatCard("Rejected", _rejectedLoans.toString(), Colors.red),
                ],
              ),

            const SizedBox(height: 32),

            // --- ONGOING APPLICATIONS ---
            const Text("Ongoing Applications", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            
            if (_isLoading)
              const Center(child: CircularProgressIndicator())
            else if (_ongoingLoans.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(color: Colors.grey[100], borderRadius: BorderRadius.circular(12)),
                child: const Center(child: Text("No active applications.", style: TextStyle(color: Colors.grey))),
              )
            else
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _ongoingLoans.length,
                itemBuilder: (context, index) {
                  final loan = _ongoingLoans[index];
                  final lFields = loan['fields'];
                  final loanName = loan['name'] ?? "";
                  final loanId = loanName.split('/').last;
                  
                  String amount = lFields['loan_amount']?['integerValue'] ?? "0";
                  double total = double.tryParse(amount) ?? 0;
                  double principal = ((total / 1.05) + 0.01).floorToDouble();

                  String date = lFields['timestamp']?['timestampValue'] ?? "";
                  DateTime dt = DateTime.tryParse(date) ?? DateTime.now();
                  
                  return Card(
                    elevation: 2,
                    margin: const EdgeInsets.only(bottom: 12),
                    child: ListTile(
                      leading: const CircleAvatar(backgroundColor: Colors.orange, child: Icon(Icons.access_time, color: Colors.white)),
                      title: Text("${_formatter.format(principal)} THB Loan"),
                      subtitle: Text("Applied: ${DateFormat('MMM d, y').format(dt)}"),
                      trailing: const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => LoanDetailsPage(
                              loanData: lFields,
                              loanId: loanId,
                              onUpdate: _fetchUserHistory, 
                              currentUserType: 'admin',
                            ),
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatCard(String title, String value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withOpacity(0.2)),
        ),
        child: Column(
          children: [
            Text(value, style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: color)),
            const SizedBox(height: 4),
            Text(title, style: TextStyle(fontSize: 12, color: color.withOpacity(0.8))),
          ],
        ),
      ),
    );
  }
}