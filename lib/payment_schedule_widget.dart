import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class PaymentScheduleWidget extends StatelessWidget {
  final double loanAmount;
  final int months;
  final double monthlySalary;

  const PaymentScheduleWidget({
    super.key,
    required this.loanAmount,
    required this.months,
    required this.monthlySalary,
  });

  @override
  Widget build(BuildContext context) {
    final formatter = NumberFormat("#,##0");

    // --- 1. SAME LOGIC AS BEFORE ---
    int totalLoanInt = loanAmount.round();
    int salaryInt = monthlySalary.round();

    if (months <= 0) return const Center(child: Text("Invalid Duration"));

    int baseDeduction = (totalLoanInt / months).floor();
    int remainder = totalLoanInt - (baseDeduction * months);

    List<Map<String, dynamic>> schedule = [];
    double totalDeduction = 0;
    double totalFinalSalary = 0;

    for (int i = 0; i < months; i++) {
      int currentDeduction = baseDeduction + (i < remainder ? 1 : 0);
      int finalSal = salaryInt - currentDeduction;

      totalDeduction += currentDeduction;
      totalFinalSalary += finalSal;

      schedule.add({
        'month': i + 1,
        'salary': salaryInt,
        'deduction': currentDeduction,
        'final': finalSal,
      });
    }

    // --- 2. NEW VISUAL DESIGN ---
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title outside the table for a cleaner look
          const Text(
            "Payment Schedule",
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.black87),
          ),
          const SizedBox(height: 16),

          // The "Contained Table" - Everything sits inside this border
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: Colors.grey.shade300),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.03),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              children: [
                // --- HEADER ---
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(11)),
                  ),
                  child: Row(
                    children: const [
                      Expanded(flex: 1, child: Text('#', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black54))),
                      Expanded(flex: 3, child: Text('Salary', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black54))),
                      Expanded(flex: 3, child: Text('Payment', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black54))),
                      Expanded(flex: 3, child: Text('Final', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black54))),
                    ],
                  ),
                ),
                
                const Divider(height: 1, thickness: 1),

                // --- DATA ROWS (Zebra Striped) ---
                ...List.generate(schedule.length, (index) {
                  final item = schedule[index];
                  // Alternating background color
                  final isEven = index % 2 == 0;
                  
                  return Container(
                    color: isEven ? Colors.white : Colors.grey.shade50,
                    padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 1,
                          child: Text("${item['month']}", 
                            style: const TextStyle(fontWeight: FontWeight.w500, color: Colors.black87)),
                        ),
                        Expanded(
                          flex: 3,
                          child: Text(formatter.format(item['salary']),
                            textAlign: TextAlign.right,
                            style: TextStyle(color: Colors.grey.shade700)),
                        ),
                        Expanded(
                          flex: 3,
                          child: Text("-${formatter.format(item['deduction'])}",
                            textAlign: TextAlign.right,
                            style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w500)),
                        ),
                        Expanded(
                          flex: 3,
                          child: Text(formatter.format(item['final']),
                            textAlign: TextAlign.right,
                            style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                  );
                }),

                const Divider(height: 1, thickness: 1),

                // --- FOOTER (TOTALS) ---
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50.withOpacity(0.5),
                    borderRadius: const BorderRadius.vertical(bottom: Radius.circular(11)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 1,
                        child: Text("All", 
                          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue.shade900)),
                      ),
                      Expanded(
                        flex: 3,
                        child: Text(formatter.format(salaryInt * months),
                          textAlign: TextAlign.right,
                          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue.shade900)),
                      ),
                      Expanded(
                        flex: 3,
                        child: Text("-${formatter.format(totalDeduction)}",
                          textAlign: TextAlign.right,
                          style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.red)),
                      ),
                      Expanded(
                        flex: 3,
                        child: Text(formatter.format(totalFinalSalary),
                          textAlign: TextAlign.right,
                          style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.green)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}