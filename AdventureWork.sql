USE AdventureWorks2022;
GO

IF OBJECT_ID('InsertOrderDetails', 'P') IS NOT NULL DROP PROCEDURE InsertOrderDetails;
IF OBJECT_ID('UpdateOrderDetails', 'P') IS NOT NULL DROP PROCEDURE UpdateOrderDetails;
IF OBJECT_ID('GetOrderDetails', 'P') IS NOT NULL DROP PROCEDURE GetOrderDetails;
IF OBJECT_ID('DeleteOrderDetails', 'P') IS NOT NULL DROP PROCEDURE DeleteOrderDetails;

IF OBJECT_ID('vwCustomerOrders', 'V') IS NOT NULL DROP VIEW vwCustomerOrders;
IF OBJECT_ID('vwCustomerOrders_Yesterday', 'V') IS NOT NULL DROP VIEW vwCustomerOrders_Yesterday;
IF OBJECT_ID('MyProducts', 'V') IS NOT NULL DROP VIEW MyProducts;

-- Drop functions
IF OBJECT_ID('FormatDate_MMDDYYYY', 'FN') IS NOT NULL DROP FUNCTION FormatDate_MMDDYYYY;
IF OBJECT_ID('FormatDate_YYYYMMDD', 'FN') IS NOT NULL DROP FUNCTION FormatDate_YYYYMMDD;


IF OBJECT_ID('Sales.trg_DeleteOrder', 'TR') IS NOT NULL DROP TRIGGER Sales.trg_DeleteOrder;
IF OBJECT_ID('Sales.trg_CheckStock', 'TR') IS NOT NULL DROP TRIGGER Sales.trg_CheckStock;
GO


CREATE PROCEDURE InsertOrderDetails
    @OrderID INT,
    @ProductID INT,
    @UnitPrice MONEY = NULL,
    @Quantity INT,
    @Discount FLOAT = 0
AS
BEGIN
    DECLARE @StockQty INT, @ReorderLevel INT, @DefaultPrice MONEY;

    SELECT @StockQty = p.SafetyStockLevel, 
           @ReorderLevel = p.ReorderPoint,
           @DefaultPrice = p.StandardCost
    FROM Production.Product p
    WHERE p.ProductID = @ProductID;

    IF @StockQty < @Quantity
    BEGIN
        PRINT 'Insufficient stock. Order cannot be placed.';
        RETURN;
    END

    IF @UnitPrice IS NULL
        SET @UnitPrice = @DefaultPrice;

    INSERT INTO Sales.SalesOrderDetail (SalesOrderID, ProductID, OrderQty, UnitPrice, UnitPriceDiscount)
    VALUES (@OrderID, @ProductID, @Quantity, @UnitPrice, @Discount);

    IF @@ROWCOUNT = 0
    BEGIN
        PRINT 'Failed to place the order. Please try again.';
        RETURN;
    END

    UPDATE Production.Product
    SET SafetyStockLevel = SafetyStockLevel - @Quantity
    WHERE ProductID = @ProductID;

    IF (SELECT SafetyStockLevel FROM Production.Product WHERE ProductID = @ProductID) < @ReorderLevel
        PRINT 'Warning: Stock has dropped below reorder level!';
END;
GO


CREATE PROCEDURE UpdateOrderDetails
    @OrderID INT,
    @ProductID INT,
    @UnitPrice MONEY = NULL,
    @Quantity INT = NULL,
    @Discount FLOAT = NULL
AS
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM Sales.SalesOrderDetail 
        WHERE SalesOrderID = @OrderID AND ProductID = @ProductID
    )
    BEGIN
        PRINT 'Invalid OrderID or ProductID.';
        RETURN;
    END

    UPDATE Sales.SalesOrderDetail
    SET 
        OrderQty = ISNULL(@Quantity, OrderQty),
        UnitPrice = ISNULL(@UnitPrice, UnitPrice),
        UnitPriceDiscount = ISNULL(@Discount, UnitPriceDiscount)
    WHERE SalesOrderID = @OrderID AND ProductID = @ProductID;
END;
GO


CREATE PROCEDURE GetOrderDetails
    @OrderID INT
AS
BEGIN
    IF NOT EXISTS (SELECT 1 FROM Sales.SalesOrderDetail WHERE SalesOrderID = @OrderID)
    BEGIN
        PRINT 'The OrderID ' + CAST(@OrderID AS VARCHAR) + ' does not exist';
        RETURN 1;
    END

    SELECT * FROM Sales.SalesOrderDetail WHERE SalesOrderID = @OrderID;
END;
GO

CREATE PROCEDURE DeleteOrderDetails
    @OrderID INT,
    @ProductID INT
AS
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM Sales.SalesOrderDetail 
        WHERE SalesOrderID = @OrderID AND ProductID = @ProductID
    )
    BEGIN
        PRINT 'Invalid OrderID or ProductID.';
        RETURN -1;
    END

    DELETE FROM Sales.SalesOrderDetail 
    WHERE SalesOrderID = @OrderID AND ProductID = @ProductID;
END;
GO


CREATE FUNCTION FormatDate_MMDDYYYY (@dt DATETIME)
RETURNS VARCHAR(10)
AS
BEGIN
    RETURN CONVERT(VARCHAR(10), @dt, 101);
END;
GO

CREATE FUNCTION FormatDate_YYYYMMDD (@dt DATETIME)
RETURNS VARCHAR(8)
AS
BEGIN
    RETURN CONVERT(VARCHAR(8), @dt, 112);
END;
GO


CREATE VIEW vwCustomerOrders AS
SELECT 
    soh.CustomerID,
    soh.SalesOrderID,
    soh.OrderDate,
    sod.ProductID,
    p.Name AS ProductName,
    sod.OrderQty AS Quantity,
    sod.UnitPrice,
    sod.OrderQty * sod.UnitPrice AS Total
FROM Sales.SalesOrderHeader soh
JOIN Sales.SalesOrderDetail sod ON soh.SalesOrderID = sod.SalesOrderID
JOIN Production.Product p ON sod.ProductID = p.ProductID;
GO


CREATE VIEW vwCustomerOrders_Yesterday AS
SELECT * FROM vwCustomerOrders
WHERE CAST(OrderDate AS DATE) = CAST(DATEADD(DAY, -1, GETDATE()) AS DATE);
GO


CREATE VIEW MyProducts AS
SELECT 
    p.ProductID,
    p.Name AS ProductName,
    p.StandardCost AS UnitPrice,
    p.Size AS QuantityPerUnit,
    s.Name AS CompanyName,
    c.Name AS CategoryName
FROM Production.Product p
JOIN Purchasing.ProductVendor pv ON p.ProductID = pv.ProductID
JOIN Purchasing.Vendor s ON pv.BusinessEntityID = s.BusinessEntityID
JOIN Production.ProductSubcategory sc ON p.ProductSubcategoryID = sc.ProductSubcategoryID
JOIN Production.ProductCategory c ON sc.ProductCategoryID = c.ProductCategoryID
WHERE p.DiscontinuedDate IS NULL OR p.DiscontinuedDate > GETDATE();
GO


CREATE TRIGGER trg_DeleteOrder
ON Sales.SalesOrderHeader
INSTEAD OF DELETE
AS
BEGIN
    DELETE sod
    FROM Sales.SalesOrderDetail sod
    JOIN deleted d ON sod.SalesOrderID = d.SalesOrderID;

    DELETE FROM Sales.SalesOrderHeader
    WHERE SalesOrderID IN (SELECT SalesOrderID FROM deleted);
END;
GO

CREATE TRIGGER trg_CheckStock
ON Sales.SalesOrderDetail
AFTER INSERT
AS
BEGIN
    DECLARE @ProductID INT, @Qty INT, @Available INT;

    SELECT TOP 1 @ProductID = i.ProductID, @Qty = i.OrderQty
    FROM inserted i;

    SELECT @Available = SafetyStockLevel FROM Production.Product WHERE ProductID = @ProductID;

    IF @Available < @Qty
    BEGIN
        RAISERROR('Not enough stock for ProductID %d. Order cannot be completed.', 16, 1, @ProductID);
        ROLLBACK;
    END
    ELSE
    BEGIN
        UPDATE Production.Product
        SET SafetyStockLevel = SafetyStockLevel - @Qty
        WHERE ProductID = @ProductID;
    END
END;
GO
