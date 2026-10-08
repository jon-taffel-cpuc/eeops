import type { ComponentType } from 'react';
import { Navigate, Route, Routes } from 'react-router';
import Layout from './components/Layout';
import { DEFAULT_PATH, NAV, type PageKey } from './nav';
import CustomersMarkets from './pages/CustomersMarkets';
import PotentialsGoals from './pages/PotentialsGoals';
import ExAnteCustom from './pages/ExAnteCustom';
import ToolsCalculators from './pages/ToolsCalculators';
import ProgramsPerformance from './pages/ProgramsPerformance';
import Evaluations from './pages/Evaluations';
import GridDetails from './pages/GridDetails';
import Consumption from './pages/Consumption';
import PoliciesProceedings from './pages/PoliciesProceedings';
import CpucAdmin from './pages/CpucAdmin';
import NotFound from './pages/NotFound';

// Page component for every key in nav.ts. TypeScript fails the build if a
// nav entry has no page here (or vice versa).
const PAGES: Record<PageKey, ComponentType> = {
  'customers-markets': CustomersMarkets,
  'potentials-goals': PotentialsGoals,
  'ex-ante-custom': ExAnteCustom,
  'tools-calculators': ToolsCalculators,
  'programs-performance': ProgramsPerformance,
  'evaluations': Evaluations,
  'grid-details': GridDetails,
  'consumption': Consumption,
  'policies-proceedings': PoliciesProceedings,
  'cpuc-admin': CpucAdmin,
};

export default function App() {
  return (
    <Layout>
      <Routes>
        <Route path="/" element={<Navigate to={DEFAULT_PATH} replace />} />
        {NAV.map(({ key, path }) => {
          const Page = PAGES[key];
          // "/*" lets a page add its own nested sub-routes later.
          return <Route key={key} path={`${path}/*`} element={<Page />} />;
        })}
        <Route path="*" element={<NotFound />} />
      </Routes>
    </Layout>
  );
}
