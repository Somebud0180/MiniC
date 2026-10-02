#include <stdio.h>

int main() {
    float notebookPrice, notebookQuantity, notebookSubtotal, ballpenPrice, ballpenQuantity, ballpenSubtotal, pencilPrice, pencilQuantity, pencilSubtotal, totalPrice;

    printf("================================\n");
    printf("School Supplies Price Calculator\n");
    printf("================================\n\n");
    
    // Notebook Subtotal
    printf("Input price of notebook: ");
    scanf("%f", &notebookPrice);

    printf("Input quantity of notebook: ");
    scanf("%f", &notebookQuantity);

    notebookSubtotal = notebookPrice * notebookQuantity;

    printf("\n");

    // Ballpen Subtotal
    printf("Input price of ballpen: ");
    scanf("%f", &ballpenPrice);

    printf("Input quantity of ballpen: ");
    scanf("%f", &ballpenQuantity);

    ballpenSubtotal = ballpenPrice * ballpenQuantity;
    
    printf("\n");

    // Pencil Subtotal
    printf("Input price of pencil: ");
    scanf("%f", &pencilPrice);

    printf("Input quantity of pencil: ");
    scanf("%f", &pencilQuantity);

    pencilSubtotal = pencilPrice * pencilQuantity;

    // Total Cost
    totalPrice = notebookSubtotal + ballpenSubtotal + pencilSubtotal;

    printf("\n----- ORDER SUMMARY -----\n");
    printf("Notebook Subtotal: %.2f\n", notebookSubtotal);
    printf("Ballpen Subtotal: %.2f\n", ballpenSubtotal);
    printf("Pencil Subtotal: %.2f\n", pencilSubtotal);
    printf("Total Cost: %.2f\n", totalPrice);

    return 0;
}
