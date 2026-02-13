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
  
  // --- User Status State ---
  late bool _isUserDisabled;
  late String _docId;

  int _totalLoans = 0;
  int _approvedLoans = 0;
  int _rejectedLoans = 0;
  
  // This list will now contain both PENDING and ONGOING (Active Repayment) loans
  List<dynamic> _activeLoansList = []; 
  
  final _formatter = NumberFormat("#,##0");

  @override
  void initState() {
    super.initState();
    _isUserDisabled = widget.userData['fields']['is_disabled']?['booleanValue'] ?? false;
    _docId = widget.userData['name'].toString().split('/').last; 
    _fetchUserHistory();
  }

  // --- HELPER: SAFE NUMBER PARSING ---
  double _parseFirestoreNumber(dynamic field) {
    if (field == null) return 0.0;
    if (field['integerValue'] != null) {
      return double.tryParse(field['integerValue'].toString()) ?? 0.0;
    }
    if (field['doubleValue'] != null) {
      return (field['doubleValue'] as num).toDouble();
    }
    return 0.0;
  }

  // --- TOGGLE DISABLE LOGIC ---
  Future<void> _toggleUserDisable(bool currentStatus) async {
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

    setState(() => _isUserDisabled = newStatus);

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

      if (response.statusCode != 200) throw "Update failed";

    } catch (e) {
      setState(() => _isUserDisabled = currentStatus);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e"), backgroundColor: Colors.red));
    }
  }

  Future<void> _fetchUserHistory() async {
    final fields = widget.userData['fields'];
    final email = fields['personal_email']?['stringValue'] ?? "";

    if (email.isEmpty) {
      setState(() => _isLoading = false);
      return;
    }

    final url = Uri.parse('https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents:runQuery');
    
    try {
      // FIX: Removed "orderBy" from the query to prevent Missing Index errors.
      // We will sort in Dart code instead.
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
        List<dynamic> data = jsonDecode(response.body);
        
        // Remove empty reads (sometimes runQuery returns a read time with no doc)
        data = data.where((item) => item['document'] != null).toList();

        // SORT HERE (Newest First)
        data.sort((a, b) {
          String tA = a['document']['fields']['timestamp']?['timestampValue'] ?? "";
          String tB = b['document']['fields']['timestamp']?['timestampValue'] ?? "";
          return tB.compareTo(tA); // Descending
        });

        int total = 0;
        int approved = 0;
        int rejected = 0;
        List<dynamic> activeList = [];

        for (var item in data) {
          final doc = item['document'];
          final loanFields = doc['fields'];
          final status = (loanFields['status']?['stringValue'] ?? "").toLowerCase();

          total++;
          
          if (status == 'rejected') {
            rejected++;
          } 
          else if (status == 'pending') {
            activeList.add(doc);
          } 
          else if (status == 'approved') {
            approved++;
            
            // --- LOGIC CHECK FOR ONGOING ---
            double totalLoanAmount = _parseFirestoreNumber(loanFields['loan_amount']);
            double totalPaid = 0.0;

            if (loanFields.containsKey('payment_history') && 
                loanFields['payment_history']['arrayValue'].containsKey('values')) {
                List<dynamic> history = loanFields['payment_history']['arrayValue']['values'];
                for (var payment in history) {
                  var amountField = payment['mapValue']?['fields']?['amount'];
                  totalPaid += _parseFirestoreNumber(amountField);
                }
            }

            // Logic: If Paid < (Total - 1), it is NOT finalized. Therefore it is Ongoing.
            if (totalPaid < (totalLoanAmount - 1)) {
              activeList.add(doc);
            }
          }
        }

        if (mounted) {
          setState(() {
            _totalLoans = total;
            _approvedLoans = approved;
            _rejectedLoans = rejected;
            _activeLoansList = activeList;
            _isLoading = false;
          });
        }
      } else {
        throw "Error fetching history: ${response.body}";
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
                  
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(color: Colors.green[50], borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.green.withOpacity(0.5))),
                    child: Text("Salary: $formattedSalary THB", style: TextStyle(color: Colors.green[800], fontWeight: FontWeight.bold)),
                  ),

                  const SizedBox(height: 16),

                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text("Active Status: ", style: TextStyle(color: Colors.grey[700], fontWeight: FontWeight.bold)),
                      Switch(
                        value: !_isUserDisabled, 
                        activeColor: Colors.green,
                        inactiveTrackColor: Colors.red[100],
                        inactiveThumbColor: Colors.red,
                        onChanged: (val) => _toggleUserDisable(_isUserDisabled),
                      ),
                      Text(_isUserDisabled ? "Disabled" : "Active", 
                        style: TextStyle(
                          color: _isUserDisabled ? Colors.red : Colors.green, 
                          fontWeight: FontWeight.bold
                        )
                      ),
                    ],
                  ),
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

            // --- ACTIVE (PENDING + ONGOING) APPLICATIONS ---
            const Text("Active Applications", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text("Includes Pending and Ongoing loans.", style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 16),
            
            if (_isLoading)
              const Center(child: CircularProgressIndicator())
            else if (_activeLoansList.isEmpty)
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
                itemCount: _activeLoansList.length,
                itemBuilder: (context, index) {
                  final loan = _activeLoansList[index];
                  final lFields = loan['fields'];
                  final loanName = loan['name'] ?? "";
                  final loanId = loanName.split('/').last;
                  
                  String status = (lFields['status']?['stringValue'] ?? "").toLowerCase();
                  
                  // Helper to get raw double for calc
                  double getVal(dynamic f) => _parseFirestoreNumber(f);
                  
                  double amountRaw = getVal(lFields['loan_amount']);
                  // Calculate principal (amount requested) vs total payback
                  double principal = ((amountRaw / 1.05) + 0.01).floorToDouble();

                  String dateStr = lFields['timestamp']?['timestampValue'] ?? "";
                  DateTime dt = DateTime.tryParse(dateStr) ?? DateTime.now();
                  
                  bool isOngoing = status == 'approved';

                  return Card(
                    elevation: 2,
                    margin: const EdgeInsets.only(bottom: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      // Different Icon for Ongoing vs Pending
                      leading: CircleAvatar(
                        backgroundColor: isOngoing ? Colors.blue.shade100 : Colors.orange.shade100,
                        child: Icon(
                          isOngoing ? Icons.sync : Icons.access_time, 
                          color: isOngoing ? Colors.blue.shade800 : Colors.orange.shade800
                        ),
                      ),
                      title: Text("${_formatter.format(principal)} THB Loan", style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("Applied: ${DateFormat('MMM d, y').format(dt)}"),
                          const SizedBox(height: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: isOngoing ? Colors.blue : Colors.orange,
                              borderRadius: BorderRadius.circular(4)
                            ),
                            child: Text(
                              isOngoing ? "ONGOING" : "PENDING",
                              style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                            ),
                          )
                        ],
                      ),
                      trailing: const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
                      onTap: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => LoanDetailsPage(
                              loanData: lFields,
                              loanId: loanId,
                              onUpdate: _fetchUserHistory, 
                              currentUserType: 'admin',
                              isAdmin: true, // Important for LoanDetailsPage to show admin controls
                            ),
                          ),
                        );
                        _fetchUserHistory();
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