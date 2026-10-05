import Customer from './components/customer';
import directory from '../public/directory.json';
import discovery from '../public/discovery.json';
export const metadata={title:'Mi Espacio · Tu tiempo. Tu lugar.',description:'Descubre negocios, bienestar y experiencias en Los Cabos. Un espacio para ti.'};
export default function Page(){return <Customer initialCatalog={{...directory,...discovery,services:[]}}/>;}
