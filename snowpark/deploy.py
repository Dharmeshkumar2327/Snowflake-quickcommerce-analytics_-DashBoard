"""
Register the Snowpark objects permanently in DASHCART.ML.

    pip install -r requirements.txt
    # ~/.snowflake/connections.toml must contain a [dashcart] connection
    python snowpark/deploy.py

Then in SQL:
    CALL DASHCART.ML.SP_SEGMENT_CUSTOMERS(3, 7);
    SELECT segment, COUNT(*) FROM DASHCART.ML.CUSTOMER_SEGMENTS GROUP BY 1;
    SELECT DASHCART.ML.HAVERSINE_KM(12.97, 77.59, 12.93, 77.62);
"""
import os
import sys

from snowflake.snowpark import Session
from snowflake.snowpark.types import FloatType, IntegerType, PandasSeriesType, StringType

sys.path.insert(0, os.path.dirname(__file__))
import customer_segmentation as cs  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    session = Session.builder.config("connection_name", os.getenv("SNOWFLAKE_CONNECTION", "dashcart")).create()
    session.use_role("DASHCART_ENGINEER")
    session.use_warehouse("DASHCART_ML_WH")
    session.use_schema("DASHCART.ML")
    session.sql("CREATE STAGE IF NOT EXISTS DASHCART.ML.SNOWPARK_CODE").collect()

    session.sproc.register_from_file(
        file_path=os.path.join(HERE, "customer_segmentation.py"),
        func_name="segment_customers",
        name="DASHCART.ML.SP_SEGMENT_CUSTOMERS",
        return_type=StringType(),
        input_types=[IntegerType(), IntegerType()],
        packages=["snowflake-snowpark-python", "scikit-learn", "pandas", "numpy"],
        is_permanent=True,
        stage_location="@DASHCART.ML.SNOWPARK_CODE",
        replace=True,
        comment="KMeans behavioural segmentation of DashCart customers",
    )

    session.udf.register(
        cs.haversine_km,
        name="DASHCART.ML.HAVERSINE_KM",
        return_type=PandasSeriesType(FloatType()),
        input_types=[PandasSeriesType(FloatType())] * 4,
        packages=["pandas", "numpy"],
        is_permanent=True,
        stage_location="@DASHCART.ML.SNOWPARK_CODE",
        replace=True,
    )

    print(session.call("DASHCART.ML.SP_SEGMENT_CUSTOMERS", 3, 7))
    cs.store_weekly_metrics(session).sort("WEEK", ascending=False).show(10)
    session.close()


if __name__ == "__main__":
    main()
