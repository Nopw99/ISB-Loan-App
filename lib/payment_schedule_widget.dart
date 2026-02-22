import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class PaymentScheduleWidget extends StatefulWidget {
  final double loanAmount;
  final int months;
  final double monthlySalary;
  final bool isAdmin;
  final bool isApproved;
  final bool isProcessing;
  final List<dynamic> paidMonths;
  final Function(int monthIndex, double amount) onMarkPaid;
  final VoidCallback onCustomPayment;

  const PaymentScheduleWidget({
    super.key,
    required this.loanAmount,
    required this.months,
    required this.monthlySalary,
    required this.isAdmin,
    required this.isApproved,
    this.isProcessing = false,
    required this.paidMonths,
    required this.onMarkPaid,
    required this.onCustomPayment,
  });

  @override
  State<PaymentScheduleWidget> createState() => _PaymentScheduleWidgetState();
}

class _PaymentScheduleWidgetState extends State<PaymentScheduleWidget> {
  late List<dynamic> _localPaidMonths;

  @override
  void initState() {
    super.initState();
    _localPaidMonths = List.from(widget.paidMonths);
  }

  @override
  void didUpdateWidget(PaymentScheduleWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.paidMonths != oldWidget.paidMonths) {
      _localPaidMonths = List.from(widget.paidMonths);
    }
  }

  @override
  Widget build(BuildContext context) {
    final _currencyFormatter = NumberFormat("#,##0");

    int baseDeduction = (widget.loanAmount / (widget.months == 0 ? 1 : widget.months)).floor();
    int remainder = widget.loanAmount.toInt() - (baseDeduction * widget.months);

    double totalPaid = 0;
    
    // SAFETY FIX 1: Safely parse amounts without crashing on nulls
    for (var p in _localPaidMonths) {
      var fields = p['mapValue']?['fields'];
      if (fields != null) {
        String amountStr = fields['amount']?['integerValue'] ?? 
                           fields['amount']?['stringValue'] ?? '0';
        totalPaid += double.tryParse(amountStr) ?? 0;
      }
    }
    
    double remaining = widget.loanAmount - totalPaid;
    bool isFullyPaid = remaining <= 0;
    double progress = widget.loanAmount > 0 ? (totalPaid / widget.loanAmount).clamp(0.0, 1.0) : 0.0;

    if (isFullyPaid) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.check_circle, size: 80, color: Colors.green),
            const SizedBox(height: 20),
            const Text("Loan Completed!",
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.black87)),
            const SizedBox(height: 10),
            Text("Total Paid: ${_currencyFormatter.format(totalPaid)} THB",
                style: TextStyle(fontSize: 16, color: Colors.grey[600])),
            const SizedBox(height: 30),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            elevation: 2,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("Remaining Balance",
                              style: TextStyle(fontSize: 14, color: Colors.grey[600], fontWeight: FontWeight.w500)),
                          const SizedBox(height: 4),
                          Text("${_currencyFormatter.format(remaining < 0 ? 0 : remaining)} THB",
                              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.blue[900])),
                        ],
                      ),
                      if (widget.isAdmin && widget.isApproved)
                        ElevatedButton.icon(
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text("Custom Pay"),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.blue[50],
                            foregroundColor: Colors.blue[900],
                            elevation: 0,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          onPressed: widget.isProcessing ? null : widget.onCustomPayment,
                        ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text("Paid: ${_currencyFormatter.format(totalPaid)} THB", 
                          style: TextStyle(fontSize: 13, color: Colors.grey[700])),
                      Text("${(progress * 100).toStringAsFixed(0)}%", 
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 8,
                      backgroundColor: Colors.grey[200],
                      valueColor: const AlwaysStoppedAnimation<Color>(Colors.green),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          const Text("Monthly Schedule",
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          const SizedBox(height: 12),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: Row(
              children: [
                SizedBox(width: 40, child: Text("Mth", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey[600], fontSize: 13))),
                Expanded(flex: 3, child: Text("Deduction", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey[600], fontSize: 13))),
                Expanded(flex: 3, child: Text("Net Sal", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey[600], fontSize: 13))),
                SizedBox(width: 60, child: Text("Status", textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey[600], fontSize: 13))),
              ],
            ),
          ),

          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Container(
              color: Colors.white,
              child: ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: widget.months,
                itemBuilder: (context, index) {
                  int monthNum = index + 1;
                  int amount = baseDeduction + (index < remainder ? 1 : 0);
                  int finalSal = widget.monthlySalary.round() - amount;

                  bool isPaid = false;
                  String paidDate = "";

                  // SAFETY FIX 2: Safely read Month Index and Dates without crashing
                  for (var p in _localPaidMonths) {
                    var fields = p['mapValue']?['fields'];
                    if (fields == null) continue;

                    String? typeStr = fields['type']?['stringValue'];
                    String? monthStr = fields['month_index']?['integerValue'] ?? fields['month_index']?['stringValue'];

                    if (typeStr == 'monthly' && monthStr != null && int.parse(monthStr) == monthNum) {
                      isPaid = true;
                      
                      // Safely grab the date, fallback to right now if missing
                      String rawDate = fields['date']?['timestampValue'] ?? 
                                       fields['date']?['stringValue'] ?? 
                                       DateTime.now().toUtc().toIso8601String();
                                       
                      paidDate = DateFormat("MMM d").format(DateTime.parse(rawDate));
                      break;
                    }
                  }

                  bool isEven = index % 2 == 0;
                  Color rowColor = isPaid ? Colors.green.withOpacity(0.15) : (isEven ? Colors.grey[50]! : Colors.white);

                  return Container(
                    color: rowColor,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 40,
                          child: Text("$monthNum", style: TextStyle(fontWeight: FontWeight.bold, color: isPaid ? Colors.green[800] : Colors.black87)),
                        ),
                        Expanded(
                          flex: 3,
                          child: Text(_currencyFormatter.format(amount), style: TextStyle(fontWeight: FontWeight.w600, color: isPaid ? Colors.green[800] : Colors.black87)),
                        ),
                        Expanded(
                          flex: 3,
                          child: Text(_currencyFormatter.format(finalSal), style: TextStyle(color: isPaid ? Colors.green[700] : Colors.grey[600], fontSize: 13)),
                        ),
                        Container(
                          width: 60,
                          alignment: Alignment.centerRight,
                          child: isPaid
                              ? Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    const Icon(Icons.check_circle, color: Colors.green, size: 20),
                                    Text(paidDate, style: const TextStyle(fontSize: 9, color: Colors.green)),
                                  ],
                                )
                              : (widget.isAdmin && widget.isApproved)
                                  ? Checkbox(
                                      value: false, 
                                      activeColor: Colors.blue,
                                      visualDensity: VisualDensity.compact,
                                      onChanged: widget.isProcessing
                                          ? null
                                          : (bool? value) {
                                              if (value == true) {
                                                setState(() {
                                                  _localPaidMonths.add({
                                                    'mapValue': {
                                                      'fields': {
                                                        'type': {'stringValue': 'monthly'},
                                                        'month_index': {'integerValue': monthNum.toString()},
                                                        'amount': {'integerValue': amount.toString()},
                                                        'date': {'timestampValue': DateTime.now().toUtc().toIso8601String()},
                                                      }
                                                    }
                                                  });
                                                });
                                                widget.onMarkPaid(monthNum, amount.toDouble());
                                              }
                                            },
                                    )
                                  : const Text("-", style: TextStyle(color: Colors.grey)),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}