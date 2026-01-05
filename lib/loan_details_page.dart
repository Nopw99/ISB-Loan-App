import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async'; 
import 'dart:typed_data'; // <--- Required for file saving
import 'package:file_saver/file_saver.dart'; // <--- Required for file saving
import 'main.dart'; 
import 'chat_widget.dart'; 
import 'payment_schedule_widget.dart'; 
import 'secrets.dart'; 

class LoanDetailsPage extends StatefulWidget {
  final Map<String, dynamic> loanData; 
  final String loanId; 
  final VoidCallback onUpdate; 
  final String currentUserType; 

  const LoanDetailsPage({
    super.key,
    required this.loanData,
    required this.loanId,
    required this.onUpdate,
    required this.currentUserType, 
  });

  @override
  State<LoanDetailsPage> createState() => _LoanDetailsPageState();
}

class _LoanDetailsPageState extends State<LoanDetailsPage> {
  bool _isProcessing = false; 
  final _currencyFormatter = NumberFormat("#,##0"); 
  final _dateFormatter = DateFormat("MMMM d, y"); 
  
  late Map<String, dynamic> _currentData;
  Timer? _pollingTimer; 

  @override
  void initState() {
    super.initState();
    _currentData = widget.loanData;
    _startPolling(); 
  }

  @override
  void dispose() {
    _pollingTimer?.cancel(); 
    super.dispose();
  }

  void _startPolling() {
    _pollingTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      _refreshData(silent: true);
    });
  }

  Future<void> _refreshData({bool silent = false}) async {
    final url = Uri.parse('https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents/loan_applications/${widget.loanId}');
    try {
      final response = await http.get(url);
      if (response.statusCode == 200) {
        if (mounted) {
          setState(() {
            _currentData = jsonDecode(response.body)['fields'];
          });
        }
      }
    } catch (e) {
      if (!silent) print("Refresh Error: $e");
    }
  }

  // --- EMAIL LOGIC ---
  Future<String> _fetchUserName(String email) async {
    final url = Uri.parse('https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents:runQuery');
    try {
      final response = await http.post(url, body: jsonEncode({
        "structuredQuery": {
          "from": [{"collectionId": "users"}],
          "where": {"fieldFilter": {"field": {"fieldPath": "personal_email"}, "op": "EQUAL", "value": {"stringValue": email}}},
          "limit": 1
        }
      }));
      if (response.statusCode == 200) {
        final List data = jsonDecode(response.body);
        if (data.isNotEmpty && data[0]['document'] != null) {
          final fields = data[0]['document']['fields'];
          String first = fields['first_name']?['stringValue'] ?? "";
          String last = fields['last_name']?['stringValue'] ?? "";
          return "$first $last".trim();
        }
      }
    } catch (e) {
      print("Name fetch error: $e");
    }
    return "Applicant"; 
  }

  Future<void> _sendEmailNotification(String userEmail, String status) async {
    String name = getString('name');
    if (name == 'N/A' || name.isEmpty) {
       name = await _fetchUserName(userEmail);
    }
    String emailStatus = status == 'approved' ? 'accepted' : 'rejected';

    final url = Uri.parse('https://api.emailjs.com/api/v1.0/email/send');
    try {
      await http.post(
        url,
        headers: {'Content-Type': 'application/json', 'Origin': 'http://localhost'},
        body: jsonEncode({
          'service_id': serviceId, 
          'template_id': notifytemp, 
          'user_id': publicKey,
          'template_params': {
            'name': name,
            'email': userEmail,
            'status': emailStatus
          }
        }),
      );
    } catch (e) {
      print("Email send error: $e");
    }
  }

  // --- UPDATED CSV DOWNLOAD LOGIC ---
  Future<void> _saveToCsv() async {
    // 1. Generate the CSV Content
    int amount = getRawAmount().round(); 
    int months = getRawMonths();
    int salary = getRawSalary().round();

    int baseDeduction = (amount / months).floor();
    int remainder = amount - (baseDeduction * months);

    String csvData = "Month,Salary,Loan Payment,Final Salary\n";
    for (int i = 0; i < months; i++) {
      int deduction = baseDeduction + (i < remainder ? 1 : 0);
      int finalSal = salary - deduction;
      csvData += "${i + 1},$salary,-$deduction,$finalSal\n";
    }
    int totalSal = salary * months;
    int totalDed = amount;
    int totalFinal = totalSal - totalDed;
    csvData += "TOTAL,$totalSal,-$totalDed,$totalFinal\n";

    // 2. Show Preview Dialog with UPDATED Download Button
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Payment Schedule (CSV)"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Preview of data to be downloaded:", style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 10),
            Container(
              height: 200, 
              width: double.maxFinite,
              padding: const EdgeInsets.all(10),
              color: Colors.grey[100],
              child: SingleChildScrollView(child: Text(csvData, style: const TextStyle(fontFamily: 'monospace', fontSize: 10))),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
          
          // --- THE REAL DOWNLOAD BUTTON ---
          ElevatedButton.icon(
            icon: const Icon(Icons.download, size: 18),
            label: const Text("Download File"),
            onPressed: () async {
              try {
                // Convert String to Bytes
                List<int> bytes = utf8.encode(csvData);
                
                // Trigger Download with User's Specific Parameters
                await FileSaver.instance.saveFile(
                  name: 'Loan_Schedule_${widget.loanId}', // Filename
                  bytes: Uint8List.fromList(bytes),
                  fileExtension: 'csv', // <--- As requested
                  mimeType: MimeType.csv,
                );
                
                if (mounted) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("File saved successfully! Check your downloads folder."), backgroundColor: Colors.green)
                  );
                }
              } catch (e) {
                print("Download Error: $e");
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text("Download failed: $e"), backgroundColor: Colors.red)
                );
              }
            }, 
          ),
        ],
      ),
    );
  }

  // --- ACTIONS (WITH VALIDATION) ---
  void _showEditDialog(String key, String label, String currentValue) {
    String cleanValue = currentValue.replaceAll(RegExp(r'[^0-9.]'), ''); 
    if (key == 'months') cleanValue = cleanValue.split('.')[0];
    TextEditingController ctrl = TextEditingController(text: cleanValue);
    
    showDialog(context: context, builder: (c) => AlertDialog(
      title: Text("Request Change: $label"),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text("This will send a proposal to the chat for the other party to accept."),
          const SizedBox(height: 10),
          TextField(controller: ctrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: "New Value", border: OutlineInputBorder())),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text("Cancel")),
        ElevatedButton(
          child: const Text("Propose"),
          onPressed: () {
            if(ctrl.text.isEmpty) return;
            double val = double.tryParse(ctrl.text) ?? 0;
            if (widget.currentUserType == 'user') {
              if (val <= 0) { _showError("Value must be greater than 0"); return; }
              if (key == 'months' && val > 12) { _showError("Duration cannot exceed 12 months"); return; }
              if (key == 'loan_amount') {
                double salary = getRawSalary();
                if (val > salary) { _showError("Loan cannot exceed monthly salary"); return; }
              }
            }
            Navigator.pop(c);
            _sendProposal(key, ctrl.text.trim(), label);
          }, 
        )
      ]
    ));
  }

  Future<void> _sendProposal(String key, String value, String label) async {
    String msg = "PROP::$key::$value::$label::PENDING";
    String cleanId = widget.loanId.contains('/') ? widget.loanId.split('/').last : widget.loanId;
    final url = Uri.parse('${rtdbUrl}chats/$cleanId.json');
    await http.post(url, body: jsonEncode({
      "text": msg,
      "sender": widget.currentUserType, 
      "timestamp": DateTime.now().toUtc().toIso8601String(),
    }));
  }

  Future<void> _handleCancel() async { 
      bool? confirm = await showDialog(context: context, builder: (context) => AlertDialog(title: const Text("Cancel?"), actions: [TextButton(onPressed: ()=>Navigator.pop(context,false), child: const Text("Keep")), TextButton(onPressed: ()=>Navigator.pop(context,true), child: const Text("Yes"))]));
      if(confirm != true) return;
      setState(() => _isProcessing = true);
      
      final url = Uri.parse('https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents/loan_applications/${widget.loanId}');
      try {
        await http.delete(url);
        await _deleteChatHistory();
        if(!mounted) return;
        Navigator.pop(context);
        widget.onUpdate();
      } catch(e) { _showError("Error: $e"); }
      setState(() => _isProcessing = false);
  }

  Future<void> _updateStatus(String newStatus, {String? reason}) async { 
    setState(() => _isProcessing = true);
    String query = "updateMask.fieldPaths=status";
    if (reason != null) query += "&updateMask.fieldPaths=rejection_reason";
    final url = Uri.parse('https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents/loan_applications/${widget.loanId}?$query');
    Map<String, dynamic> fields = {"status": {"stringValue": newStatus}};
    if (reason != null) fields["rejection_reason"] = {"stringValue": reason};
    try {
      await http.patch(url, body: jsonEncode({"fields": fields}));
      
      if (newStatus == 'approved' || newStatus == 'rejected') {
         String userEmail = getString('email');
         await _sendEmailNotification(userEmail, newStatus);
         await _deleteChatHistory();
      }
      
      if(!mounted) return;
      Navigator.pop(context); 
      widget.onUpdate();
    } catch(e) { _showError("Error: $e"); }
    setState(() => _isProcessing = false);
  }

  Future<void> _deleteChatHistory() async {
    String cleanId = widget.loanId.contains('/') ? widget.loanId.split('/').last : widget.loanId;
    final url = Uri.parse('${rtdbUrl}chats/$cleanId.json');
    await http.delete(url);
  }

  void _showRejectDialog() {
    TextEditingController reasonController = TextEditingController();
    showDialog(context: context, builder: (c) => AlertDialog(
      title: const Text("Reject"), 
      content: TextField(controller: reasonController, decoration: const InputDecoration(hintText: "Reason")),
      actions: [
        ElevatedButton(onPressed: () { Navigator.pop(c); _updateStatus('rejected', reason: reasonController.text); }, child: const Text("Reject"))
      ]
    ));
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red));
  }

  String formatDate(String? timestamp) {
    if (timestamp == null) return "N/A";
    try { return _dateFormatter.format(DateTime.parse(timestamp)); } catch (e) { return timestamp; }
  }

  String getString(String key) {
    final field = _currentData[key];
    if (field == null) return 'N/A';
    return field['stringValue'] ?? field['timestampValue'] ?? 'N/A';
  }

  String getInt(String key) {
    var val = _currentData[key]?['integerValue'];
    if (val == null) return "0";
    if (key == 'months') return int.tryParse(val.toString())?.toString() ?? "0";
    return _currencyFormatter.format(int.tryParse(val.toString()) ?? 0);
  }

  double getRawAmount() => double.tryParse(_currentData['loan_amount']?['integerValue'] ?? '0') ?? 0;
  int getRawMonths() => int.tryParse(_currentData['months']?['integerValue'] ?? '12') ?? 12;
  double getRawSalary() => double.tryParse(_currentData['salary']?['integerValue'] ?? '0') ?? 0;

  @override
  Widget build(BuildContext context) {
    String status = getString('status').toLowerCase();
    String? rejectionReason = _currentData['rejection_reason']?['stringValue'];
    bool isRejected = status == 'rejected';
    bool isPending = status == 'pending';
    bool isAdmin = widget.currentUserType == 'admin';
    bool chatReadOnly = !isPending;
    bool canEdit = isPending; 

    double dbAmount = getRawAmount(); 
    double principalAmount = ((dbAmount / 1.05) + 0.01).floorToDouble();
    double interestAmount = dbAmount - principalAmount; 
    
    return DefaultTabController(
      length: 3, 
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          title: const Text("Application Details", style: TextStyle(color: Colors.black87)),
          backgroundColor: Colors.white,
          elevation: 0,
          iconTheme: const IconThemeData(color: Colors.black87),
          actions: [
            IconButton(icon: const Icon(Icons.download, color: Colors.blue), tooltip: "Save Schedule (CSV)", onPressed: _saveToCsv)
          ],
          bottom: const TabBar(
            labelColor: Colors.blue,
            unselectedLabelColor: Colors.grey,
            indicatorColor: Colors.blue,
            tabs: [
              Tab(text: "Details", icon: Icon(Icons.description_outlined)),
              Tab(text: "Schedule", icon: Icon(Icons.table_chart_outlined)),
              Tab(text: "Chat", icon: Icon(Icons.chat_bubble_outline)),
            ],
          ),
        ),
        body: Container(
          decoration: kAppBackground,
          child: TabBarView(
            children: [
              // --- TAB 1: DETAILS ---
              SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    const SizedBox(height: 100), 
                    Card(
                      elevation: 4,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          children: [
                            Text("Current Status", style: TextStyle(color: Colors.grey[600])),
                            const SizedBox(height: 5),
                            Text(status.toUpperCase(), style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: isRejected ? Colors.red : (isPending ? Colors.orange : Colors.green))),
                            if (isRejected && rejectionReason != null) ...[
                              const Divider(height: 20),
                              Text("Reason: $rejectionReason", textAlign: TextAlign.center, style: const TextStyle(color: Colors.red)),
                            ]
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Card(
                      elevation: 4,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.blue.withOpacity(0.05),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: Colors.blue.withOpacity(0.1)),
                              ),
                              child: Column(
                                children: [
                                  _row("Loan Amount", "${_currencyFormatter.format(principalAmount)} THB", "loan_amount", canEdit),
                                  const SizedBox(height: 8),
                                  _row("Interest (5%)", "+${_currencyFormatter.format(interestAmount)} THB", "", false, isInterest: true),
                                  const Divider(),
                                  _row("Total Payback", "${_currencyFormatter.format(dbAmount)} THB", "", false, isTotal: true),
                                ],
                              ),
                            ),
                            const SizedBox(height: 20),
                            _row("Duration", "${getInt('months')} Months", "months", canEdit),
                            const Divider(height: 20),
                            _row("Salary", "${getInt('salary')} THB", "salary", false), 
                            const Divider(height: 20),
                            _row("Reason", getString('reason'), "reason", false, isLong: true),
                            const Divider(height: 20),
                            _row("Applied On", formatDate(getString('timestamp')), "", false),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 30),
                    if (isPending) ...[
                      if (isAdmin) 
                        Row(children: [
                            Expanded(child: ElevatedButton.icon(onPressed: _isProcessing ? null : () => _updateStatus('approved'), icon: const Icon(Icons.check, color: Colors.white), label: const Text("Approve", style: TextStyle(color: Colors.white)), style: ElevatedButton.styleFrom(backgroundColor: Colors.green))),
                            const SizedBox(width: 12),
                            Expanded(child: ElevatedButton.icon(onPressed: _isProcessing ? null : _showRejectDialog, icon: const Icon(Icons.close, color: Colors.white), label: const Text("Reject", style: TextStyle(color: Colors.white)), style: ElevatedButton.styleFrom(backgroundColor: Colors.red))),
                        ])
                      else 
                        SizedBox(
                          width: double.infinity, 
                          child: OutlinedButton(
                            onPressed: _isProcessing ? null : _handleCancel,
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: Colors.red),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                            child: const Text("Cancel Application", style: TextStyle(color: Colors.red)),
                          ),
                        )
                    ] else const Text("This application has been finalized.", style: TextStyle(color: Colors.grey)),
                    const SizedBox(height: 80),
                  ],
                ),
              ),
              
              // --- TAB 2: SCHEDULE ---
              Padding(
                padding: const EdgeInsets.only(top: 100),
                child: PaymentScheduleWidget(
                  loanAmount: getRawAmount(),
                  months: getRawMonths(),
                  monthlySalary: getRawSalary(),
                ),
              ),
              
              // --- TAB 3: CHAT ---
              Padding(
                padding: const EdgeInsets.only(top: 120),
                child: ChatWidget(
                  loanId: widget.loanId,
                  currentSender: widget.currentUserType,
                  isReadOnly: chatReadOnly,
                  onRefreshDetails: _refreshData, 
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(String label, String value, String key, bool canEdit, {bool isLong = false, bool isTotal = false, bool isInterest = false}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: 4, child: Text(label, style: TextStyle(
          color: isTotal ? Colors.black : Colors.grey[600],
          fontWeight: isTotal ? FontWeight.bold : FontWeight.normal
        ))),
        Expanded(
          flex: 6, 
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Flexible(child: Text(value, textAlign: TextAlign.right, style: TextStyle(
                fontWeight: isTotal ? FontWeight.w900 : FontWeight.bold, 
                fontSize: isTotal ? 16 : 14,
                color: isInterest ? Colors.green : (isTotal ? Colors.blue[900] : Colors.black)
              ))),
              if (canEdit)
                InkWell(
                  onTap: () => _showEditDialog(key, label, value),
                  child: const Padding(padding: EdgeInsets.only(left: 8), child: Icon(Icons.edit, size: 16, color: Colors.blue)),
                )
            ],
          ),
        ),
      ],
    );
  }
}